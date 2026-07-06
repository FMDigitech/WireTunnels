import CryptoKit
import Foundation
import Security

private let helperVersionNumber = "1.0"
private let applicationIdentifier = "com.fmdigitech.WireTunnels"
private let applicationTeamIdentifier = "48W4Z4X56T"
private let systemRoot = URL(fileURLWithPath: "/Library/Application Support/WireTunnels")
private let systemBinDir = systemRoot.appendingPathComponent("bin", isDirectory: true)
private let runtimeConfigDir = systemRoot.appendingPathComponent("runtime", isDirectory: true)
private let legacySystemRoot = URL(fileURLWithPath: "/Library/Application Support/WireguardTunnels")
private let legacyRuntimeConfigDirs = [
    legacySystemRoot.appendingPathComponent("runtime", isDirectory: true),
    legacySystemRoot.appendingPathComponent("wireguard", isDirectory: true)
]
private let metadataDir = systemRoot.appendingPathComponent("metadata", isDirectory: true)
private let maximumConfigSize = 1024 * 1024
private let expectedArtifactNames: Set<String> = ["wg", "wg-quick", "wireguard-go"]

private struct RuntimeManifest: Decodable {
    struct Artifact: Decodable {
        let name: String
        let sha256: String
        let size: Int64
    }

    let schemaVersion: Int
    let artifacts: [Artifact]
}

private struct ValidatedClient {
    let bundleURL: URL

    init?(connection: NSXPCConnection) {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)
        ] as CFDictionary

        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode else {
            return nil
        }

        let requirementText = """
        anchor apple generic and identifier "\(applicationIdentifier)" and \
        certificate leaf[subject.OU] = "\(applicationTeamIdentifier)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement,
        SecCodeCheckValidity(guestCode, [], requirement) == errSecSuccess else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guestCode, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
                requirement
              ) == errSecSuccess else {
            return nil
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [String: Any],
        information[kSecCodeInfoIdentifier as String] as? String == applicationIdentifier,
        information[kSecCodeInfoTeamIdentifier as String] as? String == applicationTeamIdentifier,
        let executableURL = information[kSecCodeInfoMainExecutable as String] as? URL else {
            return nil
        }

        let candidateBundle = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
        guard candidateBundle.pathExtension == "app",
              candidateBundle.appendingPathComponent("Contents/Resources/wireguard").path
                .hasPrefix(candidateBundle.path + "/") else {
            return nil
        }
        bundleURL = candidateBundle
    }
}

final class HelperTool: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener

    override init() {
        listener = NSXPCListener(machServiceName: "com.fmdigitech.WireTunnels.helper")
        super.init()
        listener.delegate = self
    }

    func run() {
        listener.resume()
        RunLoop.main.run()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let client = ValidatedClient(connection: connection) else {
            return false
        }

        let session = HelperSession(clientBundleURL: client.bundleURL)
        connection.exportedInterface = NSXPCInterface(with: WireguardHelperProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { _ = session }
        connection.resume()
        return true
    }
}

private final class HelperSession: NSObject, WireguardHelperProtocol {
    private let clientBundleURL: URL
    private let fileManager = FileManager.default

    init(clientBundleURL: URL) {
        self.clientBundleURL = clientBundleURL
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(helperVersionNumber)
    }

    func startTunnel(named name: String, reply: @escaping (Bool, String?) -> Void) {
        guard let configURL = validatedRuntimeConfig(named: name, allowLegacy: false) else {
            reply(false, "Invalid tunnel configuration name")
            return
        }

        let environment = wireGuardEnvironment()
        let result = runCommand(
            executable: systemBinDir.appendingPathComponent("wg-quick"),
            arguments: ["up", configURL.path],
            environment: environment
        )
        if result.exitCode == 0 || (result.stdout + result.stderr).contains("already exists as") {
            reply(true, nil)
        } else {
            reply(false, result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func stopTunnel(named name: String, reply: @escaping (Bool, String?) -> Void) {
        guard let configURL = validatedRuntimeConfig(named: name, allowLegacy: true) else {
            reply(false, "Invalid or missing tunnel configuration")
            return
        }

        let result = runCommand(
            executable: systemBinDir.appendingPathComponent("wg-quick"),
            arguments: ["down", configURL.path],
            environment: wireGuardEnvironment()
        )
        if result.exitCode == 0 {
            reply(true, nil)
        } else {
            reply(false, result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func runWgShow(reply: @escaping (String?, String?) -> Void) {
        let result = runCommand(
            executable: systemBinDir.appendingPathComponent("wg"),
            arguments: ["show", "all", "dump"]
        )
        if result.exitCode == 0 {
            reply(result.stdout, nil)
        } else {
            reply(nil, result.stderr.isEmpty ? "wg show failed" : result.stderr)
        }
    }

    func generateKeyPair(reply: @escaping (String?, String?, String?) -> Void) {
        do {
            let wg = try verifiedInstalledWg()
            let privateKeyResult = runCommand(executable: wg, arguments: ["genkey"])
            guard privateKeyResult.exitCode == 0 else {
                reply(nil, nil, commandError(privateKeyResult, fallback: "wg genkey failed"))
                return
            }

            let privateKey = privateKeyResult.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !privateKey.isEmpty else {
                reply(nil, nil, "wg genkey returned an empty private key")
                return
            }

            let publicKeyResult = runCommand(
                executable: wg,
                arguments: ["pubkey"],
                standardInput: privateKey + "\n"
            )
            guard publicKeyResult.exitCode == 0 else {
                reply(nil, nil, commandError(publicKeyResult, fallback: "wg pubkey failed"))
                return
            }

            let publicKey = publicKeyResult.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !publicKey.isEmpty else {
                reply(nil, nil, "wg pubkey returned an empty public key")
                return
            }

            reply(privateKey, publicKey, nil)
        } catch {
            reply(nil, nil, error.localizedDescription)
        }
    }

    func stageConfig(named name: String, contents: Data, reply: @escaping (Bool, String?) -> Void) {
        guard let safeName = validatedConfigName(name), contents.count <= maximumConfigSize else {
            reply(false, "Invalid tunnel configuration")
            return
        }

        do {
            try validateConfigContents(contents)
            try createDirectory(runtimeConfigDir, permissions: 0o700)
            let destination = runtimeConfigDir.appendingPathComponent(safeName, isDirectory: false)
            let temporary = runtimeConfigDir.appendingPathComponent(".\(UUID().uuidString).tmp")
            try contents.write(to: temporary, options: [.atomic])
            try fileManager.setAttributes([
                .posixPermissions: 0o600,
                .ownerAccountID: 0,
                .groupOwnerAccountID: 0
            ], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func installBundledTools(reply: @escaping (Bool, String?) -> Void) {
        do {
            try installVerifiedTools()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    private func installVerifiedTools() throws {
        let sourceDirectory = clientBundleURL
            .appendingPathComponent("Contents/Resources/wireguard", isDirectory: true)
        let sourceManifest = sourceDirectory.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: sourceManifest, options: .mappedIfSafe)
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: manifestData)
        let names = manifest.artifacts.map(\.name)
        guard manifest.schemaVersion == 1,
              names.count == expectedArtifactNames.count,
              Set(names).count == names.count,
              Set(names) == expectedArtifactNames else {
            throw HelperError.invalidManifest
        }

        try createDirectory(systemRoot, permissions: 0o755)
        try createDirectory(metadataDir, permissions: 0o755)

        let transaction = systemRoot.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let stagedBin = transaction.appendingPathComponent("bin", isDirectory: true)
        let backupBin = systemRoot.appendingPathComponent(".bin-backup-\(UUID().uuidString)", isDirectory: true)
        try createDirectory(stagedBin, permissions: 0o755)
        defer {
            try? fileManager.removeItem(at: transaction)
            try? fileManager.removeItem(at: backupBin)
        }

        // Bundled Mach-O binaries are re-signed by Xcode after the build phase writes
        // the manifest, so their size/sha256 in the manifest may be stale. We verify
        // copy faithfulness (source hash == destination hash) instead of comparing to
        // the potentially-stale manifest values. The installed manifest is written with
        // the actual post-signing sha256/size so verifiedInstalledWg() can verify later.
        var installedArtifactInfo: [(name: String, sha256: String, size: Int64)] = []

        for artifact in manifest.artifacts {
            guard validatedConfigName(artifact.name) == nil,
                  expectedArtifactNames.contains(artifact.name) else {
                throw HelperError.invalidManifest
            }
            let source = sourceDirectory.appendingPathComponent(artifact.name, isDirectory: false)
            try validateRegularFile(source, expectedSize: nil)
            let sourceHash = try sha256(of: source)
            let sourceSize = Int64(
                (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )

            let destination = stagedBin.appendingPathComponent(artifact.name, isDirectory: false)
            try fileManager.copyItem(at: source, to: destination)
            try fileManager.setAttributes([
                .posixPermissions: 0o755,
                .ownerAccountID: 0,
                .groupOwnerAccountID: 0
            ], ofItemAtPath: destination.path)
            guard try sha256(of: destination).caseInsensitiveCompare(sourceHash) == .orderedSame else {
                throw HelperError.hashMismatch(artifact.name)
            }
            installedArtifactInfo.append((name: artifact.name, sha256: sourceHash, size: sourceSize))
        }

        let installedManifest = metadataDir.appendingPathComponent("manifest.json")
        let stagedManifest = transaction.appendingPathComponent("manifest.json")

        // Build installed manifest with actual sha256/size so verifiedInstalledWg() can
        // verify the installed binary matches what was copied from the app bundle.
        let updatedManifestData: Data
        do {
            guard var json = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  var jsonArtifacts = json["artifacts"] as? [[String: Any]] else {
                throw HelperError.invalidManifest
            }
            let infoByName = Dictionary(uniqueKeysWithValues: installedArtifactInfo.map { ($0.name, $0) })
            for i in 0..<jsonArtifacts.count {
                if let name = jsonArtifacts[i]["name"] as? String, let info = infoByName[name] {
                    jsonArtifacts[i]["sha256"] = info.sha256
                    jsonArtifacts[i]["size"] = info.size
                }
            }
            json["artifacts"] = jsonArtifacts
            updatedManifestData = try JSONSerialization.data(withJSONObject: json)
        } catch {
            throw HelperError.invalidManifest
        }
        try updatedManifestData.write(to: stagedManifest, options: .atomic)
        try fileManager.setAttributes([
            .posixPermissions: 0o644,
            .ownerAccountID: 0,
            .groupOwnerAccountID: 0
        ], ofItemAtPath: stagedManifest.path)

        let hadExistingBin = fileManager.fileExists(atPath: systemBinDir.path)
        do {
            if hadExistingBin {
                _ = try fileManager.replaceItemAt(
                    systemBinDir,
                    withItemAt: stagedBin,
                    backupItemName: backupBin.lastPathComponent,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: stagedBin, to: systemBinDir)
            }
            if fileManager.fileExists(atPath: installedManifest.path) {
                _ = try fileManager.replaceItemAt(installedManifest, withItemAt: stagedManifest)
            } else {
                try fileManager.moveItem(at: stagedManifest, to: installedManifest)
            }
            // backupBin cleanup is handled by the defer block (try?).
            // replaceItemAt on macOS 10.13+ auto-removes the backup on success,
            // so an explicit `try` removal here would throw "file not found" and
            // incorrectly unwind an already-successful installation.
        } catch {
            try? fileManager.removeItem(at: systemBinDir)
            if hadExistingBin, fileManager.fileExists(atPath: backupBin.path) {
                try? fileManager.moveItem(at: backupBin, to: systemBinDir)
            }
            throw error
        }

        try createDirectory(runtimeConfigDir, permissions: 0o700)
    }

    private func validatedConfigName(_ name: String) -> String? {
        let interfaceName = String(name.dropLast(".conf".count))
        guard !name.isEmpty,
              name.hasSuffix(".conf"),
              !interfaceName.isEmpty,
              interfaceName.utf8.count <= 15,
              interfaceName.unicodeScalars.allSatisfy({
                CharacterSet(
                    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=+.-"
                ).contains($0)
              }),
              name == URL(fileURLWithPath: name).lastPathComponent,
              !name.contains(".."),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return name
    }

    private func validateConfigContents(_ contents: Data) throws {
        guard let text = String(data: contents, encoding: .utf8) else {
            throw HelperError.invalidConfig
        }
        let forbiddenDirectives: Set<String> = [
            "preup", "postup", "predown", "postdown"
        ]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if forbiddenDirectives.contains(key) {
                throw HelperError.privilegedHook(key)
            }
        }
    }

    private func validatedRuntimeConfig(named name: String, allowLegacy: Bool) -> URL? {
        guard let safeName = validatedConfigName(name) else { return nil }
        let candidates = allowLegacy
            ? [runtimeConfigDir] + legacyRuntimeConfigDirs
            : [runtimeConfigDir]

        for directory in candidates {
            let url = directory.appendingPathComponent(safeName, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if (try? validateRegularFile(url, expectedSize: nil)) != nil,
               let contents = try? Data(contentsOf: url, options: .mappedIfSafe),
               (try? validateConfigContents(contents)) != nil {
                return url
            }
        }
        return nil
    }

    private func validateRegularFile(_ url: URL, expectedSize: Int64?) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw HelperError.invalidFile(url.lastPathComponent)
        }
        if let expectedSize, Int64(values.fileSize ?? -1) != expectedSize {
            throw HelperError.invalidFile(url.lastPathComponent)
        }
    }

    private func verifiedInstalledWg() throws -> URL {
        let manifestURL = metadataDir.appendingPathComponent("manifest.json", isDirectory: false)
        try validateRegularFile(manifestURL, expectedSize: nil)
        try validateRootOwnedFile(manifestURL)

        let manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: manifestData)
        let names = manifest.artifacts.map(\.name)
        guard manifest.schemaVersion == 1,
              names.count == expectedArtifactNames.count,
              Set(names).count == names.count,
              Set(names) == expectedArtifactNames,
              let artifact = manifest.artifacts.first(where: { $0.name == "wg" }) else {
            throw HelperError.invalidInstalledWg
        }

        let wg = systemBinDir.appendingPathComponent("wg", isDirectory: false)
        try validateRegularFile(wg, expectedSize: artifact.size)
        try validateRootOwnedFile(wg)
        guard try sha256(of: wg).caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
            throw HelperError.invalidInstalledWg
        }
        return wg
    }

    private func validateRootOwnedFile(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o022 == 0 else {
            throw HelperError.invalidInstalledWg
        }
    }

    private func createDirectory(_ url: URL, permissions: NSNumber) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([
            .posixPermissions: permissions,
            .ownerAccountID: 0,
            .groupOwnerAccountID: 0
        ], ofItemAtPath: url.path)
    }

    private func wireGuardEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["WG_QUICK_USERSPACE_IMPLEMENTATION"] =
            systemBinDir.appendingPathComponent("wireguard-go").path
        environment["WG_SUDO"] = "1"
        return environment
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func runCommand(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: String? = nil
    ) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput == nil ? nil : Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdinPipe {
            process.standardInput = stdinPipe
        }

        do {
            try process.run()
            if let standardInput, let stdinPipe {
                try stdinPipe.fileHandleForWriting.write(contentsOf: Data(standardInput.utf8))
                try stdinPipe.fileHandleForWriting.close()
            }

            let outputGroup = DispatchGroup()
            var stdoutData = Data()
            var stderrData = Data()
            outputGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                outputGroup.leave()
            }
            outputGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                outputGroup.leave()
            }
            process.waitUntilExit()
            outputGroup.wait()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            return (stdout, stderr, process.terminationStatus)
        } catch {
            try? stdinPipe?.fileHandleForWriting.close()
            return ("", error.localizedDescription, -1)
        }
    }

    private func commandError(
        _ result: (stdout: String, stderr: String, exitCode: Int32),
        fallback: String
    ) -> String {
        let message = result.stderr.isEmpty ? result.stdout : result.stderr
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedMessage.isEmpty ? fallback : trimmedMessage
    }
}

private enum HelperError: LocalizedError {
    case invalidManifest
    case invalidFile(String)
    case hashMismatch(String)
    case invalidInstalledWg
    case invalidConfig
    case privilegedHook(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "Bundled WireGuard manifest is invalid"
        case .invalidFile(let name): return "Bundled WireGuard file is invalid: \(name)"
        case .hashMismatch(let name): return "SHA256 verification failed for \(name)"
        case .invalidInstalledWg: return "Installed WireGuard binary failed verification"
        case .invalidConfig: return "Tunnel configuration is not valid UTF-8"
        case .privilegedHook(let name):
            return "Tunnel configuration contains forbidden root command hook: \(name)"
        }
    }
}
