import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

/// Shows tunnel status and live speeds in the MacBook notch while a tunnel is connected. Off by
/// default: Settings turns the notch, its statistics and hover-only mode on and off separately.
/// Does nothing on a Mac without a notch.
@MainActor
final class NotchController: ObservableObject {
    private enum Mode { case hidden, compact, expanded }

    private let tunnelManager: TunnelManager
    private var notch: DynamicNotch<NotchExpandedView, NotchLeadingView, NotchTrailingView>?
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitors: [Any] = []
    private var collapseTimer: Timer?
    private var current = Mode.hidden
    private var desired = Mode.hidden
    private var isSyncing = false

    init(tunnelManager: TunnelManager) {
        self.tunnelManager = tunnelManager
        // Tunnel state publishes every second: wait for it to settle before looking at it.
        tunnelManager.objectWillChange.map { _ in () }
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
    }

    private var notchScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } }

    private var isWanted: Bool {
        UserDefaults.standard.bool(forKey: "notchEnabled") && tunnelManager.hasActiveTunnels && notchScreen != nil
    }

    private var restingMode: Mode { UserDefaults.standard.bool(forKey: "notchHoverOnly") ? .hidden : .compact }

    private func refresh() {
        guard isWanted else {
            collapseTimer?.invalidate()
            stopMouseMonitoring()
            desired = .hidden
            sync()
            return
        }
        if notch == nil {
            let manager = tunnelManager
            notch = DynamicNotch(style: .notch) {
                NotchExpandedView(tunnelManager: manager)
            } compactLeading: {
                NotchLeadingView(tunnelManager: manager)
            } compactTrailing: {
                NotchTrailingView(tunnelManager: manager)
            }
        }
        startMouseMonitoring()
        if desired != .expanded { desired = restingMode }
        sync()
    }

    /// Moves the notch to `desired`, one animation at a time.
    private func sync() {
        guard !isSyncing else { return }
        isSyncing = true
        Task { @MainActor in
            defer { isSyncing = false }
            while current != desired {
                let target = desired
                switch target {
                case .hidden: await notch?.hide()
                case .compact: if let screen = notchScreen { await notch?.compact(on: screen) }
                case .expanded: if let screen = notchScreen { await notch?.expand(on: screen) }
                }
                current = target
            }
        }
    }

    // MARK: - Hover

    /// The notch plus a little room on each side, where the pointer opens the expanded view.
    private func triggerRect(on screen: NSScreen) -> NSRect {
        let notchWidth = screen.frame.width - (screen.auxiliaryTopLeftArea?.width ?? 0) - (screen.auxiliaryTopRightArea?.width ?? 0)
        let width = notchWidth + 180
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - screen.safeAreaInsets.top - 2,
                      width: width, height: screen.safeAreaInsets.top + 2)
    }

    private func startMouseMonitoring() {
        guard mouseMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.pointerMoved() } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in handler(event); return event }) {
            mouseMonitors.append(local)
        }
    }

    private func stopMouseMonitoring() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
    }

    private func pointerMoved() {
        guard desired != .expanded, let screen = notchScreen,
              triggerRect(on: screen).contains(NSEvent.mouseLocation) else { return }
        desired = .expanded
        sync()
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapseIfPointerAway() }
        }
    }

    private func collapseIfPointerAway() {
        guard let screen = notchScreen else { return }
        if notch?.isHovering == true || triggerRect(on: screen).contains(NSEvent.mouseLocation) { return }
        collapseTimer?.invalidate()
        desired = restingMode
        sync()
    }
}
