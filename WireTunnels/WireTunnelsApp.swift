import SwiftUI
import AppKit

// Opens the dashboard window on every app launch, overriding SwiftUI's
// saved-close-state restoration (Window scenes remember if the user closed them).
private class AppDelegate: NSObject, NSApplicationDelegate {
    var tunnelManager: TunnelManager?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Clicking the Dock icon when all windows are closed re-opens the dashboard.
        if !hasVisibleWindows {
            NSApp.windows
                .first { $0.title == "WireTunnels" }?
                .makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let tm = tunnelManager, tm.hasActiveTunnels else { return .terminateNow }
        Task { @MainActor in
            await tm.stopAllActive()
            NSApp.reply(toApplicationShouldTerminate: true)
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
        _tunnelManager = StateObject(wrappedValue: TunnelManager())
        _dashboardNavigation = StateObject(wrappedValue: DashboardNavigation())
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
                            hasError: tunnelManager.errorMessage != nil)
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
    let hasActive: Bool
    let hasWarnings: Bool
    let hasError: Bool

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(iconColor, .primary)
            .task {
                openWindow(id: "dashboard")
            }
    }

    private var iconName: String {
        hasActive ? "network" : "network.slash"
    }

    private var iconColor: Color {
        if hasError { return .red }
        if hasWarnings { return .yellow }
        if hasActive { return .green }
        return .primary
    }
}
