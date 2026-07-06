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

struct AutoConnectRule: Codable, Equatable, Hashable {
    var enabled: Bool                   = false
    var interface: AutoConnectInterface = .wifi
    /// Empty = any Wi-Fi network; non-empty = only the listed SSIDs
    var wifiSSIDs: [String]             = []

    var matchesAnyWiFi: Bool { wifiSSIDs.isEmpty }
}
