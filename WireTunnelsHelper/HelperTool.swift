import CryptoKit
import Darwin
import Foundation
import Security

private let helperVersionNumber = "1.0.1"
private let helperProtocolRevisionValue = "managed-users-v1"
private let applicationIdentifier = "com.fmdigitech.WireTunnels"
private let applicationTeamIdentifier = "48W4Z4X56T"
private let systemRoot = URL(fileURLWithPath: "/Library/Application Support/WireTunnels")
private let systemBinDir = systemRoot.appendingPathComponent("bin", isDirectory: true)
private let runtimeConfigDir = systemRoot.appendingPathComponent("runtime", isDirectory: true)
private let managedRoot = systemRoot.appendingPathComponent("managed", isDirectory: true)
private let managedConfigDir = managedRoot.appendingPathComponent("configs", isDirectory: true)
private let managedMetadataDir = managedRoot.appendingPathComponent("metadata", isDirectory: true)
private let managedMetadataFile = managedMetadataDir.appendingPathComponent("tunnels.json", isDirectory: false)
private let managedConnectedUsersFile = managedMetadataDir.appendingPathComponent("connected-users.json", isDirectory: false)
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

private enum ManagedAutoConnectInterface: String, Codable {
    case ethernet
    case wifi
    case both
}

private enum ManagedAutoConnectAction: String, Codable {
    case connect
    case disconnect
}

private struct ManagedAutoConnectRule: Codable, Equatable {
    var enabled: Bool = false
    var interface: ManagedAutoConnectInterface = .wifi
    var action: ManagedAutoConnectAction = .connect
    var wifiSSIDs: [String] = []
}

private struct ManagedTunnelPolicy: Codable, Equatable {
    var usersCanConnect: Bool = true
    var usersCanDisconnect: Bool = true
}

private struct ManagedTunnelRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var configPath: String
    var runtimeConfigPath: String?
    var interfaceName: String?
    var isActive: Bool
    var isFavorite: Bool
    var autostart: Bool
    var autoConnectRule: ManagedAutoConnectRule
    var address: [String]?
    var allowedIPs: [String]
    var dns: [String]
    var endpoint: String?
    var publicKey: String?
    var lastHandshake: Date?
    var rxBytes: Int64
    var txBytes: Int64
    var connectedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var scope: String
    var managedPolicy: ManagedTunnelPolicy?
}

private struct ManagedTunnelUserSession: Codable, Equatable {
    var uid: Int
    var username: String
    var connectedAt: Date
}

private struct SanitizedConfigMetadata {
    var address: [String]
    var allowedIPs: [String]
    var dns: [String]
    var endpoint: String?
    var publicKey: String?
}

private struct ClientUser {
    let uid: Int
    let username: String
}

private enum ConfigName {
    static func sanitize(_ name: String) -> String {
        let rawName = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=+.-"
        )
        let sanitized = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .reduce("") { $0 + String($1) }
            .replacingOccurrences(of: "..", with: "__")
        return String(sanitized.prefix(15))
    }

    static func nonEmptyList(_ value: String) -> [String] {
        value.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

private struct ValidatedClient {
    let bundleURL: URL
    let user: ClientUser

    init?(connection: NSXPCConnection) {
        guard let user = Self.user(for: connection.processIdentifier) else {
            return nil
        }

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
        self.user = user
    }

    private static func user(for pid: pid_t) -> ClientUser? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == MemoryLayout<proc_bsdinfo>.size else { return nil }
        let uid = Int(info.pbi_uid)
        let username: String
        if let passwd = getpwuid(uid_t(uid)) {
            username = String(cString: passwd.pointee.pw_name)
        } else {
            username = "uid \(uid)"
        }
        return ClientUser(uid: uid, username: username)
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

        let session = HelperSession(clientBundleURL: client.bundleURL, clientUser: client.user)
        connection.exportedInterface = NSXPCInterface(with: WireguardHelperProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { _ = session }
        connection.resume()
        return true
    }
}

private final class HelperSession: NSObject, WireguardHelperProtocol {
    private let clientBundleURL: URL
    private let clientUser: ClientUser
    private let fileManager = FileManager.default

    init(clientBundleURL: URL, clientUser: ClientUser) {
        self.clientBundleURL = clientBundleURL
        self.clientUser = clientUser
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(helperVersionNumber)
    }

    func helperProtocolRevision(reply: @escaping (String) -> Void) {
        reply(helperProtocolRevisionValue)
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

    func listManagedTunnels(reply: @escaping (Data?, String?) -> Void) {
        do {
            try ensureManagedStore()
            let records = try loadManagedRecords()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            reply(try encoder.encode(records), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func installManagedTunnel(
        named name: String,
        contents: Data,
        authorization: Data,
        reply: @escaping (Bool, String?) -> Void
    ) {
        do {
            try validateAdminAuthorization(authorization)
            guard contents.count <= maximumConfigSize else { throw HelperError.invalidConfig }
            try validateConfigContents(contents)
            let safeBaseName = ConfigName.sanitize(name)
            guard let safeName = validatedConfigName("\(safeBaseName).conf") else {
                throw HelperError.invalidConfigName
            }
            try ensureManagedStore()

            var records = try loadManagedRecords()
            guard !records.contains(where: { URL(fileURLWithPath: $0.configPath).lastPathComponent == safeName }) else {
                throw HelperError.managedTunnelExists
            }

            let configURL = managedConfigDir.appendingPathComponent(safeName, isDirectory: false)
            guard !fileManager.fileExists(atPath: configURL.path) else {
                throw HelperError.managedTunnelExists
            }
            try writeManagedConfig(contents, to: configURL)
            let metadata = try sanitizedMetadata(from: contents)
            let now = Date()
            records.append(ManagedTunnelRecord(
                id: UUID(),
                name: safeBaseName,
                configPath: configURL.path,
                runtimeConfigPath: nil,
                interfaceName: nil,
                isActive: false,
                isFavorite: false,
                autostart: false,
                autoConnectRule: ManagedAutoConnectRule(),
                address: metadata.address,
                allowedIPs: metadata.allowedIPs,
                dns: metadata.dns,
                endpoint: metadata.endpoint,
                publicKey: metadata.publicKey,
                lastHandshake: nil,
                rxBytes: 0,
                txBytes: 0,
                connectedAt: nil,
                createdAt: now,
                updatedAt: now,
                scope: "managed",
                managedPolicy: ManagedTunnelPolicy()
            ))
            try saveManagedRecords(records)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func updateManagedTunnel(
        id: String,
        name: String,
        contents: Data?,
        policy: Data,
        autoConnectRule: Data,
        authorization: Data,
        reply: @escaping (Bool, String?) -> Void
    ) {
        do {
            try validateAdminAuthorization(authorization)
            try ensureManagedStore()
            var records = try loadManagedRecords()
            guard let uuid = UUID(uuidString: id),
                  let index = records.firstIndex(where: { $0.id == uuid }) else {
                throw HelperError.managedTunnelNotFound
            }
            let decoder = JSONDecoder()
            let decodedPolicy = try decoder.decode(ManagedTunnelPolicy.self, from: policy)
            let decodedRule = try decoder.decode(ManagedAutoConnectRule.self, from: autoConnectRule)
            let safeBaseName = ConfigName.sanitize(name)
            guard let safeName = validatedConfigName("\(safeBaseName).conf") else {
                throw HelperError.invalidConfigName
            }

            let oldConfigURL = URL(fileURLWithPath: records[index].configPath)
            let newConfigURL = managedConfigDir.appendingPathComponent(safeName, isDirectory: false)
            let metadata: SanitizedConfigMetadata?
            if let contents {
                guard contents.count <= maximumConfigSize else { throw HelperError.invalidConfig }
                try validateConfigContents(contents)
                metadata = try sanitizedMetadata(from: contents)
                try writeManagedConfig(contents, to: newConfigURL)
            } else {
                try validateManagedConfigFile(oldConfigURL)
                metadata = nil
                if oldConfigURL.path != newConfigURL.path {
                    guard !fileManager.fileExists(atPath: newConfigURL.path) else {
                        throw HelperError.managedTunnelExists
                    }
                    try fileManager.moveItem(at: oldConfigURL, to: newConfigURL)
                    try fileManager.setAttributes([
                        .posixPermissions: 0o600,
                        .ownerAccountID: 0,
                        .groupOwnerAccountID: 0
                    ], ofItemAtPath: newConfigURL.path)
                }
            }
            if oldConfigURL.path != newConfigURL.path, fileManager.fileExists(atPath: oldConfigURL.path) {
                try? fileManager.removeItem(at: oldConfigURL)
            }

            records[index].name = safeBaseName
            records[index].configPath = newConfigURL.path
            records[index].autoConnectRule = decodedRule
            records[index].managedPolicy = decodedPolicy
            if let metadata {
                records[index].address = metadata.address
                records[index].allowedIPs = metadata.allowedIPs
                records[index].dns = metadata.dns
                records[index].endpoint = metadata.endpoint
                records[index].publicKey = metadata.publicKey
            }
            records[index].updatedAt = Date()
            try saveManagedRecords(records)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func deleteManagedTunnel(id: String, authorization: Data, reply: @escaping (Bool, String?) -> Void) {
        do {
            try validateAdminAuthorization(authorization)
            try ensureManagedStore()
            var records = try loadManagedRecords()
            guard let uuid = UUID(uuidString: id),
                  let record = records.first(where: { $0.id == uuid }) else {
                throw HelperError.managedTunnelNotFound
            }
            records.removeAll { $0.id == uuid }
            let configURL = URL(fileURLWithPath: record.configPath)
            if fileManager.fileExists(atPath: configURL.path) {
                try validateManagedConfigFile(configURL)
                try fileManager.removeItem(at: configURL)
            }
            var connectedUsers = try loadManagedConnectedUsers()
            connectedUsers.removeValue(forKey: id)
            try saveManagedConnectedUsers(connectedUsers)
            try saveManagedRecords(records)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func stageManagedConfig(id: String, reply: @escaping (String?, String?) -> Void) {
        do {
            try ensureManagedStore()
            let records = try loadManagedRecords()
            guard let uuid = UUID(uuidString: id),
                  let record = records.first(where: { $0.id == uuid }) else {
                throw HelperError.managedTunnelNotFound
            }
            let source = URL(fileURLWithPath: record.configPath)
            try validateManagedConfigFile(source)
            let contents = try Data(contentsOf: source, options: .mappedIfSafe)
            try validateConfigContents(contents)
            try createDirectory(runtimeConfigDir, permissions: 0o700)
            let destination = runtimeConfigDir.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            try writeRuntimeConfig(contents, to: destination)
            reply(destination.path, nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func markManagedTunnelConnected(id: String, reply: @escaping (Bool, String?) -> Void) {
        do {
            try ensureManagedStore()
            let records = try loadManagedRecords()
            guard UUID(uuidString: id) != nil,
                  records.contains(where: { $0.id.uuidString == id }) else {
                throw HelperError.managedTunnelNotFound
            }
            var connectedUsers = try loadManagedConnectedUsers()
            var sessions = connectedUsers[id, default: []]
            sessions.removeAll { $0.uid == clientUser.uid }
            sessions.append(ManagedTunnelUserSession(
                uid: clientUser.uid,
                username: clientUser.username,
                connectedAt: Date()
            ))
            connectedUsers[id] = sessions.sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
            try saveManagedConnectedUsers(connectedUsers)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func markManagedTunnelDisconnected(id: String, reply: @escaping (Bool, String?) -> Void) {
        do {
            try ensureManagedStore()
            guard UUID(uuidString: id) != nil else {
                throw HelperError.managedTunnelNotFound
            }
            var connectedUsers = try loadManagedConnectedUsers()
            var sessions = connectedUsers[id, default: []]
            sessions.removeAll { $0.uid == clientUser.uid }
            if sessions.isEmpty {
                connectedUsers.removeValue(forKey: id)
            } else {
                connectedUsers[id] = sessions
            }
            try saveManagedConnectedUsers(connectedUsers)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func listManagedTunnelUsers(id: String, authorization: Data, reply: @escaping (Data?, String?) -> Void) {
        do {
            try validateAdminAuthorization(authorization)
            try ensureManagedStore()
            let records = try loadManagedRecords()
            guard UUID(uuidString: id) != nil,
                  records.contains(where: { $0.id.uuidString == id }) else {
                throw HelperError.managedTunnelNotFound
            }
            let sessions = try loadManagedConnectedUsers()[id, default: []]
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            reply(try encoder.encode(sessions), nil)
        } catch {
            reply(nil, error.localizedDescription)
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

    private func ensureManagedStore() throws {
        try createDirectory(systemRoot, permissions: 0o755)
        try createDirectory(managedRoot, permissions: 0o755)
        try createDirectory(managedConfigDir, permissions: 0o700)
        try createDirectory(managedMetadataDir, permissions: 0o755)
        if fileManager.fileExists(atPath: managedMetadataFile.path) {
            try validateRegularFile(managedMetadataFile, expectedSize: nil)
            try validateRootOwnedFile(managedMetadataFile)
        }
        if fileManager.fileExists(atPath: managedConnectedUsersFile.path) {
            try validateRegularFile(managedConnectedUsersFile, expectedSize: nil)
            try validateRootOwnedFile(managedConnectedUsersFile)
        }
    }

    private func loadManagedRecords() throws -> [ManagedTunnelRecord] {
        guard fileManager.fileExists(atPath: managedMetadataFile.path) else { return [] }
        try validateRegularFile(managedMetadataFile, expectedSize: nil)
        try validateRootOwnedFile(managedMetadataFile)
        let data = try Data(contentsOf: managedMetadataFile, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ManagedTunnelRecord].self, from: data)
    }

    private func saveManagedRecords(_ records: [ManagedTunnelRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        let temporary = managedMetadataDir.appendingPathComponent(".tunnels-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([
            .posixPermissions: 0o644,
            .ownerAccountID: 0,
            .groupOwnerAccountID: 0
        ], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: managedMetadataFile.path) {
            _ = try fileManager.replaceItemAt(managedMetadataFile, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: managedMetadataFile)
        }
    }

    private func loadManagedConnectedUsers() throws -> [String: [ManagedTunnelUserSession]] {
        guard fileManager.fileExists(atPath: managedConnectedUsersFile.path) else { return [:] }
        try validateRegularFile(managedConnectedUsersFile, expectedSize: nil)
        try validateRootOwnedFile(managedConnectedUsersFile)
        let data = try Data(contentsOf: managedConnectedUsersFile, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: [ManagedTunnelUserSession]].self, from: data)
    }

    private func saveManagedConnectedUsers(_ connectedUsers: [String: [ManagedTunnelUserSession]]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(connectedUsers)
        let temporary = managedMetadataDir.appendingPathComponent(".connected-users-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([
            .posixPermissions: 0o600,
            .ownerAccountID: 0,
            .groupOwnerAccountID: 0
        ], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: managedConnectedUsersFile.path) {
            _ = try fileManager.replaceItemAt(managedConnectedUsersFile, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: managedConnectedUsersFile)
        }
    }

    private func writeManagedConfig(_ contents: Data, to destination: URL) throws {
        try validateConfigContents(contents)
        let temporary = managedConfigDir.appendingPathComponent(".\(UUID().uuidString).tmp")
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
    }

    private func writeRuntimeConfig(_ contents: Data, to destination: URL) throws {
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
    }

    private func validateManagedConfigFile(_ url: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(managedConfigDir.standardizedFileURL.path + "/"),
              validatedConfigName(url.lastPathComponent) != nil else {
            throw HelperError.invalidConfigName
        }
        try validateRegularFile(url, expectedSize: nil)
        try validateRootOwnedFile(url)
    }

    private func validateAdminAuthorization(_ authorization: Data) throws {
        guard authorization.count == MemoryLayout<AuthorizationExternalForm>.size else {
            throw HelperError.authorizationRequired
        }
        var externalForm = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &externalForm) { buffer in
            authorization.copyBytes(to: buffer)
        }
        var authRef: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&externalForm, &authRef) == errAuthorizationSuccess,
              let authRef else {
            throw HelperError.authorizationRequired
        }
        try "system.privilege.admin".withCString { rightName in
            var item = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            try withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                guard AuthorizationCopyRights(authRef, &rights, nil, AuthorizationFlags(), nil) == errAuthorizationSuccess else {
                    throw HelperError.authorizationRequired
                }
            }
        }
    }

    private func sanitizedMetadata(from contents: Data) throws -> SanitizedConfigMetadata {
        guard let text = String(data: contents, encoding: .utf8) else {
            throw HelperError.invalidConfig
        }
        var section = ""
        var peerCount = 0
        var address: [String] = []
        var allowedIPs: [String] = []
        var dns: [String] = []
        var endpoint: String?
        var publicKey: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line.lowercased()
                if section == "[peer]" { peerCount += 1 }
                continue
            }
            let parts = line.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1...].joined(separator: "=").trimmingCharacters(in: .whitespaces)
            if section == "[interface]" {
                switch key {
                case "address": address = ConfigName.nonEmptyList(value)
                case "dns": dns = ConfigName.nonEmptyList(value)
                default: break
                }
            } else if section == "[peer]" && peerCount == 1 {
                switch key {
                case "publickey": publicKey = value.isEmpty ? nil : value
                case "endpoint": endpoint = value.isEmpty ? nil : value
                case "allowedips": allowedIPs = ConfigName.nonEmptyList(value)
                default: break
                }
            }
        }

        guard !address.isEmpty, !allowedIPs.isEmpty, publicKey != nil else {
            throw HelperError.invalidConfig
        }
        return SanitizedConfigMetadata(
            address: address,
            allowedIPs: allowedIPs,
            dns: dns,
            endpoint: endpoint,
            publicKey: publicKey
        )
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
    case invalidConfigName
    case authorizationRequired
    case managedTunnelExists
    case managedTunnelNotFound
    case privilegedHook(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "Bundled WireGuard manifest is invalid"
        case .invalidFile(let name): return "Bundled WireGuard file is invalid: \(name)"
        case .hashMismatch(let name): return "SHA256 verification failed for \(name)"
        case .invalidInstalledWg: return "Installed WireGuard binary failed verification"
        case .invalidConfig: return "Tunnel configuration is not valid UTF-8"
        case .invalidConfigName: return "Managed tunnel name is invalid"
        case .authorizationRequired: return "Administrator authorization is required"
        case .managedTunnelExists: return "A managed tunnel with that name already exists"
        case .managedTunnelNotFound: return "Managed tunnel was not found"
        case .privilegedHook(let name):
            return "Tunnel configuration contains forbidden root command hook: \(name)"
        }
    }
}
