import Foundation
import UserNotifications

@MainActor
protocol NotificationDelivering {
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
private final class UserNotificationCenterDelivery: NotificationDelivering {
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        )
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    static let showNotificationsPreferenceKey = "showNotifications"

    private let defaults: UserDefaults
    private let delivery: NotificationDelivering

    init(
        defaults: UserDefaults = .standard,
        delivery: NotificationDelivering? = nil
    ) {
        self.defaults = defaults
        let usesSystemDelivery = delivery == nil
        self.delivery = delivery ?? UserNotificationCenterDelivery()
        super.init()
        if usesSystemDelivery {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    // Show notifications even when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    @discardableResult
    func setNotificationsEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            defaults.set(false, forKey: Self.showNotificationsPreferenceKey)
            return false
        }

        do {
            let granted = try await delivery.requestAuthorization()
            defaults.set(granted, forKey: Self.showNotificationsPreferenceKey)
            return granted
        } catch {
            defaults.set(false, forKey: Self.showNotificationsPreferenceKey)
            LogService.shared.error(
                "Notification authorization failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    func postConnected(tunnelName: String) async throws {
        try await post(
            title: "Tunnel Connected",
            body: "\(tunnelName) connected successfully."
        )
    }

    func postDisconnected(tunnelName: String) async throws {
        try await post(
            title: "Tunnel Disconnected",
            body: "\(tunnelName) disconnected."
        )
    }

    func postError(tunnelName: String, message: String) async throws {
        try await post(
            title: "Tunnel Error",
            body: "\(tunnelName): \(message)"
        )
    }

    private func post(title: String, body: String) async throws {
        guard defaults.bool(forKey: Self.showNotificationsPreferenceKey) else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try await delivery.add(request)
    }
}
