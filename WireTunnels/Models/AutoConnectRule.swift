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

enum AutoConnectAction: String, Codable, CaseIterable, Hashable {
    case connect
    case disconnect

    var displayName: String {
        switch self {
        case .connect: return "Connect"
        case .disconnect: return "Disconnect"
        }
    }
}

struct AutoConnectRule: Codable, Equatable, Hashable {
    var enabled: Bool                   = false
    var interface: AutoConnectInterface = .wifi
    var action: AutoConnectAction       = .connect
    /// Empty = any Wi-Fi network; non-empty = only the listed SSIDs
    var wifiSSIDs: [String]             = []

    var matchesAnyWiFi: Bool { wifiSSIDs.isEmpty }

    init(
        enabled: Bool = false,
        interface: AutoConnectInterface = .wifi,
        action: AutoConnectAction = .connect,
        wifiSSIDs: [String] = []
    ) {
        self.enabled = enabled
        self.interface = interface
        self.action = action
        self.wifiSSIDs = wifiSSIDs
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case interface
        case action
        case wifiSSIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        interface = try container.decodeIfPresent(AutoConnectInterface.self, forKey: .interface) ?? .wifi
        action = try container.decodeIfPresent(AutoConnectAction.self, forKey: .action) ?? .connect
        wifiSSIDs = try container.decodeIfPresent([String].self, forKey: .wifiSSIDs) ?? []
    }
}
