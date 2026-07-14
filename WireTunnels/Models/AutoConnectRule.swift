import Foundation

enum AutoConnectInterface: String, Codable, CaseIterable, Hashable {
    case ethernet
    case wifi
    case both

    var displayName: String {
        switch self {
        case .ethernet: return "Ethernet"
        case .wifi:     return "Wi-Fi"
        case .both:     return "Ethernet & Wi-Fi"
        }
    }
}

/// One half of an on-demand rule: either the "connect on these networks" side or
/// the "disconnect on these networks" side. The two halves are independent so a
/// tunnel can, for example, connect on the office Wi-Fi and disconnect on a public
/// hotspot without one setting overwriting the other.
struct AutoConnectNetworkMatch: Codable, Equatable, Hashable {
    var enabled: Bool                   = false
    var interface: AutoConnectInterface = .wifi
    /// Empty = any Wi-Fi network; non-empty = only the listed SSIDs
    var wifiSSIDs: [String]             = []

    var matchesAnyWiFi: Bool { wifiSSIDs.isEmpty }

    init(
        enabled: Bool = false,
        interface: AutoConnectInterface = .wifi,
        wifiSSIDs: [String] = []
    ) {
        self.enabled = enabled
        self.interface = interface
        self.wifiSSIDs = wifiSSIDs
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case interface
        case wifiSSIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        interface = try container.decodeIfPresent(AutoConnectInterface.self, forKey: .interface) ?? .wifi
        wifiSSIDs = try container.decodeIfPresent([String].self, forKey: .wifiSSIDs) ?? []
    }
}

struct AutoConnectRule: Codable, Equatable, Hashable {
    var connect: AutoConnectNetworkMatch    = AutoConnectNetworkMatch()
    var disconnect: AutoConnectNetworkMatch = AutoConnectNetworkMatch()

    /// Whether either half is configured — drives whether this rule gets evaluated at all.
    var enabled: Bool { connect.enabled || disconnect.enabled }

    init(
        connect: AutoConnectNetworkMatch = AutoConnectNetworkMatch(),
        disconnect: AutoConnectNetworkMatch = AutoConnectNetworkMatch()
    ) {
        self.connect = connect
        self.disconnect = disconnect
    }

    private enum CodingKeys: String, CodingKey {
        case connect
        case disconnect
        // Pre-existing flat shape: a single enabled/interface/action/wifiSSIDs rule.
        // Kept only so old persisted tunnels (personal JSON store and managed
        // tunnels written by an older helper) migrate cleanly on first load.
        case enabled
        case interface
        case action
        case wifiSSIDs
    }

    private enum LegacyAction: String, Codable {
        case connect
        case disconnect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard container.contains(.action) else {
            connect = try container.decodeIfPresent(AutoConnectNetworkMatch.self, forKey: .connect)
                ?? AutoConnectNetworkMatch()
            disconnect = try container.decodeIfPresent(AutoConnectNetworkMatch.self, forKey: .disconnect)
                ?? AutoConnectNetworkMatch()
            return
        }

        let legacyEnabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let legacyInterface = try container.decodeIfPresent(AutoConnectInterface.self, forKey: .interface) ?? .wifi
        let legacyAction = try container.decodeIfPresent(LegacyAction.self, forKey: .action) ?? .connect
        let legacySSIDs = try container.decodeIfPresent([String].self, forKey: .wifiSSIDs) ?? []
        let legacyMatch = AutoConnectNetworkMatch(
            enabled: legacyEnabled,
            interface: legacyInterface,
            wifiSSIDs: legacySSIDs
        )
        switch legacyAction {
        case .connect:
            connect = legacyMatch
            disconnect = AutoConnectNetworkMatch()
        case .disconnect:
            connect = AutoConnectNetworkMatch()
            disconnect = legacyMatch
        }
    }

    // CodingKeys carries legacy-only cases (enabled/interface/action/wifiSSIDs) that
    // don't map to stored properties, which disables encode(to:) synthesis — so it's
    // spelled out here instead. Always writes the new connect/disconnect shape.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(connect, forKey: .connect)
        try container.encode(disconnect, forKey: .disconnect)
    }
}
