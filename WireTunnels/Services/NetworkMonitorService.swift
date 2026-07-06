import Foundation
import Network
import CoreWLAN
import Combine
import OSLog

/// Monitors active network interfaces and drives auto-connect/disconnect logic.
@MainActor
final class NetworkMonitorService: ObservableObject {
    @Published private(set) var isOnEthernet: Bool   = false
    @Published private(set) var isOnWiFi: Bool       = false
    @Published private(set) var currentSSID: String? = nil

    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "com.fmdigitech.WireTunnels.netmon", qos: .utility)
    private let log     = Logger(subsystem: "com.fmdigitech.WireTunnels", category: "NetworkMonitor")

    /// Called on every network path change (already dispatched to MainActor).
    var onNetworkChange: (() async -> Void)?

    // Tunnels connected by the auto-connect rule (not by the user)
    private var autoConnectedIDs: Set<UUID>  = []
    // Tunnels the user manually disconnected while the rule was matching —
    // prevents immediate reconnect until the matching network is lost and rejoined.
    private var suppressedIDs: Set<UUID>     = []

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let onWifi     = path.usesInterfaceType(.wifi)
            let onEthernet = path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ssid: String? = onWifi ? Self.fetchCurrentSSID() : nil
                self.isOnWiFi     = onWifi
                self.isOnEthernet = onEthernet
                self.currentSSID  = ssid
                self.log.info("Network change — wifi=\(onWifi) ethernet=\(onEthernet) ssid=\(ssid ?? "nil")")
                await self.onNetworkChange?()
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    // MARK: - Rule matching

    func matchesTunnel(_ tunnel: Tunnel) -> Bool {
        let rule = tunnel.autoConnectRule
        guard rule.enabled else { return false }
        switch rule.interface {
        case .ethernet: return isOnEthernet
        case .wifi:     return matchesWiFi(rule: rule)
        case .both:     return isOnEthernet || matchesWiFi(rule: rule)
        }
    }

    private func matchesWiFi(rule: AutoConnectRule) -> Bool {
        guard isOnWiFi else { return false }
        if rule.matchesAnyWiFi { return true }
        guard let ssid = currentSSID else { return false }
        return rule.wifiSSIDs.contains(ssid)
    }

    // MARK: - Auto-connect state tracking

    func markAutoConnected(_ id: UUID)        { autoConnectedIDs.insert(id) }
    func markAutoDisconnected(_ id: UUID)     { autoConnectedIDs.remove(id) }
    func wasAutoConnected(_ id: UUID) -> Bool { autoConnectedIDs.contains(id) }

    /// Call when the user manually disconnects — suppresses reconnect while network still matches.
    func userDidDisconnect(_ id: UUID) {
        autoConnectedIDs.remove(id)
        suppressedIDs.insert(id)
    }

    /// Call when the user manually connects — lifts suppression.
    func userDidConnect(_ id: UUID) {
        suppressedIDs.remove(id)
        autoConnectedIDs.remove(id)
    }

    /// Clear suppression for a tunnel whose network condition stopped matching.
    /// Next time the matching network appears it will auto-connect again.
    func clearSuppression(_ id: UUID) {
        suppressedIDs.remove(id)
    }

    func isSuppressed(_ id: UUID) -> Bool { suppressedIDs.contains(id) }

    // MARK: - SSID helpers

    static func fetchCurrentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }
}
