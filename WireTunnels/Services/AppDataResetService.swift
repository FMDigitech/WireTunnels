import Foundation

extension Notification.Name {
    static let appDataDidReset = Notification.Name("WireTunnels.appDataDidReset")
}

final class AppDataResetService {
    static let shared = AppDataResetService()

    private let userDataDirectories: [URL]
    private let defaults: UserDefaults
    private let defaultsDomain: String
    private let notificationCenter: NotificationCenter
    private let fileManager: FileManager

    init(
        userDataDirectories: [URL] = [
            AppPaths.userConfigDir,
            AppPaths.userMetadataDir,
            AppPaths.userLogsDir
        ],
        defaults: UserDefaults = .standard,
        defaultsDomain: String = Bundle.main.bundleIdentifier
            ?? "com.fmdigitech.WireTunnels",
        notificationCenter: NotificationCenter = .default,
        fileManager: FileManager = .default
    ) {
        self.userDataDirectories = userDataDirectories
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
        self.notificationCenter = notificationCenter
        self.fileManager = fileManager
    }

    func reset(completion: (() -> Void)? = nil) throws {
        for directory in userDataDirectories
        where fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }

        defaults.removePersistentDomain(forName: defaultsDomain)
        notificationCenter.post(name: .appDataDidReset, object: self)
        completion?()
    }
}
