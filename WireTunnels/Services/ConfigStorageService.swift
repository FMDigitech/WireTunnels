import Foundation

final class ConfigStorageService {
    private let fm = FileManager.default
    private let configDirectory: URL

    init(configDirectory: URL = AppPaths.userConfigDir) {
        self.configDirectory = configDirectory
        try? fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    }

    /// Import a .conf file using an interface-safe filename.
    func importConfig(from sourceURL: URL) throws -> URL {
        let rawName = sourceURL.deletingPathExtension().lastPathComponent
        let name = ConfigStorageService.displayName(for: rawName)
        try validateDisplayName(name)
        let destURL = try destinationURL(for: ConfigStorageService.fileBaseName(for: name))
        guard !fm.fileExists(atPath: destURL.path) else {
            throw ConfigStorageError.alreadyExists(name)
        }
        try fm.copyItem(at: sourceURL, to: destURL)
        try secureConfigPermissions(at: destURL)
        return destURL
    }

    /// Keep the user's display name separate from the restricted config filename.
    static func displayName(for name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
    }

    /// wg-quick accepts only 1-15 ASCII interface-name characters in filenames.
    /// Preserve existing safe aliases; hash names that need conversion or shortening.
    static let maxInterfaceNameLength = 15

    static func fileBaseName(for displayName: String) -> String {
        // Swift compares canonically equivalent display names as equal.
        // Their config aliases must agree as well, including when editing.
        let name = self.displayName(for: displayName).precomposedStringWithCanonicalMapping
        let base = name.hasSuffix(".conf") ? String(name.dropLast(".conf".count)) : name
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=+.-"
        )
        let safeBase = base
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .reduce("") { $0 + String($1) }
            .replacingOccurrences(of: "..", with: "__")
        // A trailing dot would create ".." when the .conf extension is appended.
        guard base.isEmpty || base.hasSuffix(".") || safeBase != base || base.utf8.count > maxInterfaceNameLength else { return base }
        // FNV-1a keeps the suffix stable across launches (Hasher is randomly seeded).
        var hash: UInt32 = 2166136261
        for byte in (base.isEmpty ? name : base).utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        let suffix = String(format: "%06x", hash & 0xFFFFFF)
        let prefix = safeBase.isEmpty ? "tunnel" : String(safeBase.prefix(maxInterfaceNameLength - suffix.count - 1))
        return "\(prefix)-\(suffix)"
    }

    /// Save config content as a new file. `name` is the display name.
    func saveConfig(
        name: String,
        content: String,
        replacingExisting: Bool = false
    ) throws -> URL {
        try validateDisplayName(ConfigStorageService.displayName(for: name))
        let destURL = try destinationURL(for: ConfigStorageService.fileBaseName(for: name))
        if fm.fileExists(atPath: destURL.path), !replacingExisting {
            throw ConfigStorageError.alreadyExists(name)
        }
        try content.write(to: destURL, atomically: true, encoding: .utf8)
        try secureConfigPermissions(at: destURL)
        return destURL
    }

    /// Delete a config file
    func deleteConfig(at url: URL) throws {
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// List all .conf files in user config dir
    func listConfigs() -> [URL] {
        let contents = try? fm.contentsOfDirectory(
            at: configDirectory,
            includingPropertiesForKeys: nil
        )
        return (contents ?? []).filter { $0.pathExtension == "conf" }
    }

    /// Read config file contents
    func readConfig(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func destinationURL(for name: String) throws -> URL {
        let baseName = name
        guard !baseName.isEmpty,
              baseName.utf8.count <= ConfigStorageService.maxInterfaceNameLength,
              !baseName.contains(".."),
              baseName.unicodeScalars.allSatisfy({
                CharacterSet(
                    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=+.-"
                ).contains($0)
              }) else {
            throw ConfigStorageError.invalidName(name)
        }
        return configDirectory.appendingPathComponent("\(baseName).conf", isDirectory: false)
    }

    private func validateDisplayName(_ name: String) throws {
        guard !name.isEmpty,
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw ConfigStorageError.invalidName(name)
        }
    }

    private func secureConfigPermissions(at url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum ConfigStorageError: LocalizedError {
    case invalidName(String)
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a tunnel name without control characters (up to 50 characters)."
        case .alreadyExists(let name):
            return "A tunnel named \"\(name)\" already exists"
        }
    }
}
