import SwiftUI
import AppKit

extension Notification.Name {
    static let openDashboardRequested = Notification.Name("WireTunnels.openDashboardRequested")
}

// Opens the dashboard window on every app launch (unless "Start in background" is on),
// overriding SwiftUI's saved-close-state restoration (Window scenes remember if the user closed them).
private class AppDelegate: NSObject, NSApplicationDelegate {
    var tunnelManager: TunnelManager?
    private var terminationPending = false

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Clicking the Dock icon when all windows are closed re-opens the dashboard.
        if !hasVisibleWindows {
            if let window = NSApp.windows.first(where: { $0.title == "WireTunnels" }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                // Started in background: the dashboard window was never created.
                NotificationCenter.default.post(name: .openDashboardRequested, object: nil)
            }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        guard let manager = tunnelManager ?? AppIntentBridge.tunnelManager else { return .terminateNow }
        terminationPending = true
        Task { @MainActor in
            while await !manager.prepareForQuit() {
                let alert = NSAlert()
                alert.messageText = "WireTunnels could not disconnect safely"
                alert.informativeText = (manager.quitFailureReason ?? "Tunnel cleanup failed.")
                    + "\n\n" + (manager.errorMessage ?? "Check the connection and try again.")
                alert.addButton(withTitle: "Retry")
                alert.addButton(withTitle: "Cancel Quit")
                if alert.runModal() != .alertFirstButtonReturn {
                    await manager.cancelQuit()
                    self.terminationPending = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            self.terminationPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct WireTunnelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var tunnelManager: TunnelManager
    @StateObject private var dashboardNavigation: DashboardNavigation
    @StateObject private var updaterService = UpdaterService()

    init() {
        AppMigration.migrateIfNeeded()
        // Apply the Dock preference before SwiftUI creates the menu-bar item.
        NSApplication.shared.setActivationPolicy(
            UserDefaults.standard.bool(forKey: "hideDockIcon") ? .accessory : .regular
        )
        let manager = TunnelManager()
        _tunnelManager = StateObject(wrappedValue: manager)
        _dashboardNavigation = StateObject(wrappedValue: DashboardNavigation())
        AppIntentBridge.tunnelManager = manager
    }

    var body: some Scene {
        let _ = { appDelegate.tunnelManager = tunnelManager }()

        MenuBarExtra {
            MenuBarView()
                .environmentObject(tunnelManager)
                .environmentObject(dashboardNavigation)
        } label: {
            MenuBarIconView(hasActive: tunnelManager.hasActiveTunnels,
                            hasWarnings: !tunnelManager.activeWarnings.isEmpty,
                            hasError: tunnelManager.errorMessage != nil,
                            connectionStatus: tunnelManager.menuBarConnectionStatus)
        }
        .menuBarExtraStyle(.window)

        Window("WireTunnels", id: "dashboard") {
            MainDashboardView()
                .environmentObject(tunnelManager)
                .environmentObject(dashboardNavigation)
                .environmentObject(updaterService)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(tunnelManager)
                .environmentObject(updaterService)
        }
    }
}

// MARK: - Menu bar icon

private struct MenuBarIconView: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("launchInBackground") private var launchInBackground = false
    @AppStorage("monochromeMenuBarIcon") private var monochromeMenuBarIcon = false
    let hasActive: Bool
    let hasWarnings: Bool
    let hasError: Bool
    let connectionStatus: TunnelConnectionStatus

    var body: some View {
        Image(nsImage: statusImage)
            .help(iconDescription)
            .accessibilityLabel("WireTunnels: \(iconDescription)")
            .task {
                guard !launchInBackground else { return }
                openWindow(id: "dashboard")
            }
            .onReceive(NotificationCenter.default.publisher(for: .openDashboardRequested)) { _ in
                openWindow(id: "dashboard")
            }
    }

    private var iconName: String {
        connectionStatus.menuBarImage(hasWarnings: hasWarnings, hasError: hasError)
    }

    private var iconDescription: String {
        if hasError { return "Error - open WireTunnels for details" }
        if hasWarnings && (connectionStatus == .idle || connectionStatus == .connected) {
            return "Warning - open WireTunnels for details"
        }
        return connectionStatus.description
    }

    /// An AppKit image is placed by the status bar like the system's own items; a SwiftUI
    /// symbol in the label sat higher than its neighbours (discussion #44).
    private var statusImage: NSImage {
        let symbol = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) ?? NSImage()
        var configuration = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
        if let iconColor {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [iconColor, .labelColor]))
        }
        let image = symbol.withSymbolConfiguration(configuration) ?? symbol
        // A template follows the menu bar's light/dark and highlighted appearance.
        image.isTemplate = iconColor == nil
        return image
    }

    /// Nil draws the icon as a template in the menu bar's own color.
    private var iconColor: NSColor? {
        if monochromeMenuBarIcon { return nil }
        if hasError { return .systemRed }
        if connectionStatus == .connectionLost { return .systemRed }
        if connectionStatus == .connecting || connectionStatus == .reconnecting { return .systemOrange }
        if hasWarnings { return .systemYellow }
        if hasActive { return .systemGreen }
        return nil
    }
}
