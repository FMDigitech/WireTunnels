import Foundation

enum TunnelWarning: Identifiable, Equatable {
    case multipleFullTunnels([String])       // tunnel names with 0.0.0.0/0
    case fullTunnelActive(String)            // single tunnel with 0.0.0.0/0
    case overlappingAllowedIPs(String, String) // tunnel A and B have overlapping IPs
    case conflictingDNS([String])            // active tunnels with different DNS

    var id: String {
        switch self {
        case .multipleFullTunnels(let names): return "multipleFullTunnels-\(names.joined())"
        case .fullTunnelActive(let name): return "fullTunnelActive-\(name)"
        case .overlappingAllowedIPs(let a, let b): return "overlappingIPs-\(a)-\(b)"
        case .conflictingDNS(let names): return "conflictingDNS-\(names.joined())"
        }
    }

    var title: String {
        switch self {
        case .multipleFullTunnels: return "Multiple Full Tunnels"
        case .fullTunnelActive: return "Full Tunnel Active"
        case .overlappingAllowedIPs: return "Overlapping Routes"
        case .conflictingDNS: return "DNS Conflict"
        }
    }

    var message: String {
        switch self {
        case .multipleFullTunnels(let names):
            return "Multiple full-tunnel VPNs active: \(names.joined(separator: ", ")). This may break routing or DNS."
        case .fullTunnelActive(let name):
            return "Tunnel \"\(name)\" routes all traffic (0.0.0.0/0) through the VPN."
        case .overlappingAllowedIPs(let a, let b):
            return "Tunnels \"\(a)\" and \"\(b)\" have overlapping AllowedIPs. Traffic may be routed incorrectly."
        case .conflictingDNS(let names):
            return "Active tunnels \(names.joined(separator: ", ")) define different DNS servers. Resolution may be unpredictable."
        }
    }

    var severity: WarningSeverity {
        switch self {
        case .multipleFullTunnels: return .error
        case .fullTunnelActive: return .warning
        case .overlappingAllowedIPs: return .warning
        case .conflictingDNS: return .info
        }
    }
}

enum WarningSeverity {
    case info, warning, error
}
