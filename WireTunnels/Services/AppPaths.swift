import Foundation

enum AppPaths {
    static let systemRoot = URL(fileURLWithPath: "/Library/Application Support/WireTunnels")
    static let systemBinDir = systemRoot.appendingPathComponent("bin", isDirectory: true)
    static let runtimeConfigDir = systemRoot.appendingPathComponent("runtime", isDirectory: true)
    static let systemMetadataDir = systemRoot.appendingPathComponent("metadata", isDirectory: true)
    static let installedManifest = systemMetadataDir.appendingPathComponent("manifest.json")
    static let managedRoot = systemRoot.appendingPathComponent("managed", isDirectory: true)
    static let managedConfigDir = managedRoot.appendingPathComponent("configs", isDirectory: true)
    static let managedMetadataDir = managedRoot.appendingPathComponent("metadata", isDirectory: true)
    static let managedMetadataFile = managedMetadataDir.appendingPathComponent("tunnels.json")

    static let legacySystemRoot = URL(fileURLWithPath: "/Library/Application Support/WireguardTunnels")
    static let legacyRuntimeConfigDir = legacySystemRoot.appendingPathComponent("runtime", isDirectory: true)
    static let legacyWireguardRuntimeConfigDir = legacySystemRoot.appendingPathComponent("wireguard", isDirectory: true)

    static var userRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WireTunnels", isDirectory: true)
    }

    static var userConfigDir: URL {
        userRoot.appendingPathComponent("configs", isDirectory: true)
    }

    static var userMetadataDir: URL {
        userRoot.appendingPathComponent("metadata", isDirectory: true)
    }

    static var metadataFile: URL {
        userMetadataDir.appendingPathComponent("tunnels.json")
    }

    static var userLogsDir: URL {
        userRoot.appendingPathComponent("logs", isDirectory: true)
    }

    static var logFile: URL {
        userLogsDir.appendingPathComponent("WireTunnels.log")
    }

    static var legacyUserRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WireguardTunnels", isDirectory: true)
    }

    static var legacyUserConfigDir: URL {
        legacyUserRoot.appendingPathComponent("configs", isDirectory: true)
    }

    static var legacyUserMetadataFile: URL {
        legacyUserRoot.appendingPathComponent("metadata/tunnels.json")
    }

    static var legacyUserRootMetadataFile: URL {
        legacyUserRoot.appendingPathComponent("tunnels.json")
    }

    static var legacyUserLogFile: URL {
        legacyUserRoot.appendingPathComponent("logs/WireguardTunnels.log")
    }

    static var legacyLibraryLogFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WireguardTunnels/WireguardTunnels.log")
    }

    static let wgPath = "/Library/Application Support/WireTunnels/bin/wg"
    static let wgQuickPath = "/Library/Application Support/WireTunnels/bin/wg-quick"
    static let wireguardGoPath = "/Library/Application Support/WireTunnels/bin/wireguard-go"

    /// Path inside app bundle where binaries are embedded at build time
    static var bundledBinariesDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("wireguard")
    }

    static var bundledManifest: URL? {
        bundledBinariesDir?.appendingPathComponent("manifest.json")
    }
}
