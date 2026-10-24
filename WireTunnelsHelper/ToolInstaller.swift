import CryptoKit
import Foundation
import OSLog
import Security

enum ToolInstallError: LocalizedError {
    case bundleUnavailable
    case unknownTool(String)
    case notRegularFile(String)
    case unsafeOwnership(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundleUnavailable: return "The helper could not locate the WireGuard tools in its app bundle"
        case .unknownTool(let name): return "Unknown WireGuard tool: \(name)"
        case .notRegularFile(let name): return "WireGuard tool is not a regular file: \(name)"
        case .unsafeOwnership(let name): return "WireGuard tool location is not protected: \(name)"
        case .verificationFailed(let name): return "WireGuard tool failed verification: \(name)"
        }
    }
}

/// Installs and verifies the WireGuard tools the helper runs as root.
/// Tools always come from the helper's own app bundle and are checked against anchors
/// compiled into the helper, on copies only the helper can write. No XPC client chooses
/// the source or the files.
final class ToolInstaller {
    enum Check {
        /// Signed Mach-O: a code requirement survives Xcode re-signing, a build-time hash doesn't.
        case codeSignature(requirement: String)
        /// Unsigned script: pinned to the exact bytes this helper was built with.
        case sha256(String)
    }

    struct Tool {
        let name: String
        let check: Check
    }

    struct Owner {
        let uid: uid_t
        let gid: gid_t

        static let root = Owner(uid: 0, gid: 0)
    }

    let tools: [Tool]
    private let source: () throws -> URL
    private let binDirectory: URL
    private let owner: Owner
    private let fileManager = FileManager.default
    // Serializes installs and verifications from helper start, XPC calls and tool launches.
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.fmdigitech.WireTunnels", category: "tool-installer")
    // Also receives each logged message, so the helper can pass it on to the app's log.
    private let onEvent: (_ isError: Bool, _ message: String) -> Void

    init(tools: [Tool], source: @escaping () throws -> URL, binDirectory: URL, owner: Owner = .root,
         onEvent: @escaping (_ isError: Bool, _ message: String) -> Void = { _, _ in }) {
        self.tools = tools
        self.source = source
        self.binDirectory = binDirectory
        self.owner = owner
        self.onEvent = onEvent
    }

    /// `Contents/Resources/wireguard` of the app bundle the running helper was launched from:
    /// …/WireTunnels.app/Contents/Library/LaunchDaemons/<helper executable>
    static func bundledToolsDirectory(executable: URL? = Bundle.main.executableURL) throws -> URL {
        guard let executable = executable?.resolvingSymlinksInPath() else {
            throw ToolInstallError.bundleUnavailable
        }
        let bundle = executable
            .deletingLastPathComponent()   // LaunchDaemons
            .deletingLastPathComponent()   // Library
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // WireTunnels.app
        let expected = bundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(executable.lastPathComponent)")
        guard bundle.pathExtension == "app", expected.path == executable.path else {
            throw ToolInstallError.bundleUnavailable
        }
        return bundle.appendingPathComponent("Contents/Resources/wireguard", isDirectory: true)
    }

    /// Verifies the named installed tools (all tools when `names` is nil).
    func verifyInstalled(_ names: [String]? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        try verify(try selectedTools(names))
    }

    /// Verifies the named installed tools and reinstalls every tool from the helper's own
    /// bundle when any of them is missing or fails verification.
    func ensureInstalled(_ names: [String]? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        let selected = try selectedTools(names)
        let firstInstall = !itemExists(binDirectory)
        do {
            try verify(selected)
            return
        } catch {
            // Once bin/ exists, only root can change it, so a failed check here means someone did.
            if firstInstall {
                report(.default, "Installing WireGuard tools from the helper's bundle")
            } else {
                report(.error, "Installed WireGuard tools failed verification, reinstalling: \(error.localizedDescription)")
            }
        }
        do {
            try install()
            try verify(selected)
            report(.default, "Installed WireGuard tools from the helper's bundle")
        } catch {
            report(.fault, "WireGuard tools could not be installed: \(error.localizedDescription)")
            throw error
        }
    }

    private func report(_ type: OSLogType, _ message: String) {
        logger.log(level: type, "\(message, privacy: .public)")
        onEvent(type == .error || type == .fault, message)
    }

    /// Like fileExists, but a dangling symlink counts as existing instead of missing.
    private func itemExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func selectedTools(_ names: [String]?) throws -> [Tool] {
        guard let names else { return tools }
        return try names.map { name in
            guard let tool = tools.first(where: { $0.name == name }) else { throw ToolInstallError.unknownTool(name) }
            return tool
        }
    }

    private func verify(_ selected: [Tool]) throws {
        // A writable bin/ or parent would let its files be swapped after this check.
        for directory in [binDirectory.deletingLastPathComponent(), binDirectory] {
            try requireProtected(directory, name: directory.lastPathComponent)
        }
        for tool in selected {
            let url = binDirectory.appendingPathComponent(tool.name, isDirectory: false)
            try requireRegularFile(url, name: tool.name)
            try requireProtected(url, name: tool.name)
            try check(url, tool: tool)
        }
    }

    private func install() throws {
        let sourceDirectory = try source()
        let root = binDirectory.deletingLastPathComponent()
        let transaction = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let staged = transaction.appendingPathComponent("bin", isDirectory: true)
        try createOwnedDirectory(root, intermediate: true)
        // A helper stopped mid-install (e.g. replaced during re-registration) never ran its cleanup.
        // The lock and the single helper process mean no other install is using these.
        for name in try fileManager.contentsOfDirectory(atPath: root.path) where name.hasPrefix(".install-") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
        try createOwnedDirectory(transaction)
        defer { try? fileManager.removeItem(at: transaction) }
        try createOwnedDirectory(staged)

        for tool in tools {
            let destination = staged.appendingPathComponent(tool.name, isDirectory: false)
            try fileManager.copyItem(at: sourceDirectory.appendingPathComponent(tool.name, isDirectory: false), to: destination)
            // copyItem copies a symlink as a symlink. The staging folder belongs to the
            // helper, so the copy can't change between these checks and the swap.
            try requireRegularFile(destination, name: tool.name)
            try fileManager.setAttributes([
                .posixPermissions: 0o755,
                .ownerAccountID: owner.uid,
                .groupOwnerAccountID: owner.gid
            ], ofItemAtPath: destination.path)
            try check(destination, tool: tool)
        }

        // Only a fully verified set replaces bin/; any failure above leaves the current tools in place.
        // By default replaceItemAt keeps the old folder's permissions, which may be the reason for
        // reinstalling, so take only the staged folder's.
        if fileManager.fileExists(atPath: binDirectory.path) {
            _ = try fileManager.replaceItemAt(binDirectory, withItemAt: staged, options: .usingNewMetadataOnly)
        } else {
            try fileManager.moveItem(at: staged, to: binDirectory)
        }
    }

    private func check(_ url: URL, tool: Tool) throws {
        switch tool.check {
        case .sha256(let expected):
            guard try Self.sha256(of: url).caseInsensitiveCompare(expected) == .orderedSame else {
                throw ToolInstallError.verificationFailed(tool.name)
            }
        case .codeSignature(let requirementText):
            var code: SecStaticCode?
            var requirement: SecRequirement?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                  let code,
                  SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
                  let requirement,
                  SecStaticCodeCheckValidity(
                      code,
                      SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
                      requirement
                  ) == errSecSuccess else {
                throw ToolInstallError.verificationFailed(tool.name)
            }
        }
    }

    private func requireRegularFile(_ url: URL, name: String) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ToolInstallError.notRegularFile(name)
        }
    }

    private func requireProtected(_ url: URL, name: String) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == owner.uid,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o022 == 0 else {
            throw ToolInstallError.unsafeOwnership(name)
        }
    }

    private func createOwnedDirectory(_ url: URL, intermediate: Bool = false) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: intermediate)
        try fileManager.setAttributes([
            .posixPermissions: 0o755,
            .ownerAccountID: owner.uid,
            .groupOwnerAccountID: owner.gid
        ], ofItemAtPath: url.path)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
