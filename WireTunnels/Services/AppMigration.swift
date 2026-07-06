import Foundation

enum AppMigration {
    private static let legacyDefaultsDomain = "com.fmdigitech.WireguardTunnels"
    private static let migrationMarker = "wireTunnelsMigrationCompleted"
    private static let preferenceKeys = [
        "launchAtLogin",
        "showNotifications",
        "showRawOutput"
    ]

    static func migrateIfNeeded() {
        migrateUserDataIfNeeded()
        migratePreferencesIfNeeded()
    }

    static func migrateUserDataIfNeeded(fileManager: FileManager = .default) {
        let directories = [
            AppPaths.userRoot,
            AppPaths.userConfigDir,
            AppPaths.userMetadataDir,
            AppPaths.userLogsDir
        ]
        for directory in directories {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        copyMissingContents(
            from: AppPaths.legacyUserConfigDir,
            to: AppPaths.userConfigDir,
            fileManager: fileManager
        )
        copyFirstExisting(
            sources: [
                AppPaths.legacyUserMetadataFile,
                AppPaths.legacyUserRootMetadataFile
            ],
            destination: AppPaths.metadataFile,
            fileManager: fileManager
        )
        copyFirstExisting(
            sources: [
                AppPaths.legacyUserLogFile,
                AppPaths.legacyLibraryLogFile
            ],
            destination: AppPaths.logFile,
            fileManager: fileManager
        )
    }

    static func migratePreferencesIfNeeded(
        defaults: UserDefaults = .standard,
        legacyDomain: [String: Any]? = nil
    ) {
        guard !defaults.bool(forKey: migrationMarker) else { return }
        let source = legacyDomain
            ?? defaults.persistentDomain(forName: legacyDefaultsDomain)
            ?? [:]

        for key in preferenceKeys where defaults.object(forKey: key) == nil {
            if let value = source[key] {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationMarker)
    }

    private static func copyFirstExisting(
        sources: [URL],
        destination: URL,
        fileManager: FileManager
    ) {
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        for source in sources where fileManager.fileExists(atPath: source.path) {
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: source, to: destination)
                return
            } catch {
                continue
            }
        }
    }

    static func copyMissingContents(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: source.path),
              let contents = try? fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for sourceItem in contents {
            let destinationItem = destination.appendingPathComponent(sourceItem.lastPathComponent)
            guard !fileManager.fileExists(atPath: destinationItem.path) else { continue }
            try? fileManager.copyItem(at: sourceItem, to: destinationItem)
        }
    }
}
