import AppKit

/// A window-style menu extra also needs clicks delivered to other windows/apps.
@MainActor
final class MenuBarDismissalController {
    private static let navigationRequested = Notification.Name("WireTunnels.menuBarNavigationRequested")
    private weak var window: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    private var navigationObserver: NSObjectProtocol?

    init(window: NSWindow) {
        self.window = window
    }

    static func performNavigation(_ action: () -> Void) {
        NotificationCenter.default.post(name: navigationRequested, object: nil)
        action()
    }

    func start() {
        guard localMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            self?.dismissIfOutside(event.window)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.dismissIfOutside(nil)
        }
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissIfOutside(nil) }
        }
        navigationObserver = NotificationCenter.default.addObserver(
            forName: Self.navigationRequested, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.window?.close() }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        if let navigationObserver { NotificationCenter.default.removeObserver(navigationObserver) }
        localMonitor = nil
        globalMonitor = nil
        deactivateObserver = nil
        navigationObserver = nil
    }

    private func dismissIfOutside(_ clickedWindow: NSWindow?) {
        guard let window, window.isVisible, window.attachedSheet == nil else { return }
        // The status item toggles the menu itself; closing first would reopen it.
        if clickedWindow?.level == .statusBar { return }
        var candidate = clickedWindow
        while let current = candidate {
            if current === window { return }
            candidate = current.parent ?? current.sheetParent
        }
        window.close()
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        if let navigationObserver { NotificationCenter.default.removeObserver(navigationObserver) }
    }
}
