import Foundation

final class ConfigStorageService {
    private let fm = FileManager.default
    private let configDirectory: URL

    init(configDirectory: URL = AppPaths.userConfigDir) {
        self.configDirectory = configDirectory
        try? fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    }

    /// Import a .conf file — copy to userConfigDir, sanitizing filename for wg-quick compatibility
    func importConfig(from sourceURL: URL) throws -> URL {
        let rawName = sourceURL.deletingPathExtension().lastPathComponent
        let sanitizedName = ConfigStorageService.sanitize(name: rawName)
        let destURL = try destinationURL(for: sanitizedName)
        guard !fm.fileExists(atPath: destURL.path) else {
            throw ConfigStorageError.alreadyExists(sanitizedName)
        }
        try fm.copyItem(at: sourceURL, to: destURL)
        try secureConfigPermissions(at: destURL)
        return destURL
    }

    /// Sanitize a tunnel name for use as a wg-quick interface name.
    /// Spaces and non-alphanumeric chars (except - and _) become underscores.
    static func sanitize(name: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=+.-"
        )
        let sanitized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .reduce("") { $0 + String($1) }
        let traversalSafe = sanitized.replacingOccurrences(of: "..", with: "__")
        return String(traversalSafe.prefix(15))
    }

    /// Save config content as a new file
    func saveConfig(
        name: String,
        content: String,
        replacingExisting: Bool = false
    ) throws -> URL {
        let destURL = try destinationURL(for: name)
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
        let baseName = name.hasSuffix(".conf")
            ? String(name.dropLast(".conf".count))
            : name
        guard !baseName.isEmpty,
              baseName.utf8.count <= 15,
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
            return "Tunnel names must use 1-15 ASCII letters, digits, or _ = + . -"
        case .alreadyExists(let name):
            return "A tunnel named \"\(name)\" already exists"
        }
    }
}
