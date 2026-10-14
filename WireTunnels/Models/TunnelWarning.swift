import Foundation

enum TunnelWarning: Identifiable, Equatable {
    case multipleFullTunnels([String])       // tunnel names with 0.0.0.0/0
    case overlappingAllowedIPs(String, String) // tunnel A and B have overlapping IPs
    case conflictingDNS([String])            // active tunnels with different DNS
    case killSwitchBlocking(String)          // tunnel dropped unexpectedly, kill switch is blocking traffic

    var id: String {
        switch self {
        case .multipleFullTunnels(let names): return "multipleFullTunnels-\(names.joined())"
        case .overlappingAllowedIPs(let a, let b): return "overlappingIPs-\(a)-\(b)"
        case .conflictingDNS(let names): return "conflictingDNS-\(names.joined())"
        case .killSwitchBlocking(let name): return "killSwitchBlocking-\(name)"
        }
    }

    var title: String {
        switch self {
        case .multipleFullTunnels: return "Multiple Full Tunnels"
        case .overlappingAllowedIPs: return "Overlapping Routes"
        case .conflictingDNS: return "DNS Conflict"
        case .killSwitchBlocking: return "Kill Switch Active"
        }
    }

    var message: String {
        switch self {
        case .multipleFullTunnels(let names):
            return "Multiple full-tunnel VPNs active: \(names.joined(separator: ", ")). This may break routing or DNS."
        case .overlappingAllowedIPs(let a, let b):
            return "Tunnels \"\(a)\" and \"\(b)\" have overlapping AllowedIPs. Traffic may be routed incorrectly."
        case .conflictingDNS(let names):
            return "Active tunnels \(names.joined(separator: ", ")) define different DNS servers. Resolution may be unpredictable."
        case .killSwitchBlocking(let name):
            return "\"\(name)\" dropped unexpectedly. All non-tunnel traffic is blocked until it reconnects or you disable its kill switch."
        }
    }

    var severity: WarningSeverity {
        switch self {
        case .multipleFullTunnels: return .error
        case .overlappingAllowedIPs: return .warning
        case .conflictingDNS: return .info
        case .killSwitchBlocking: return .error
        }
    }
}

enum WarningSeverity {
    case info, warning, error
}
