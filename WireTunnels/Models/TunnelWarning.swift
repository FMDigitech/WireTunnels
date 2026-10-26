import Foundation

enum TunnelWarning: Identifiable, Equatable {
    case multipleFullTunnels([String])       // tunnel names with 0.0.0.0/0
    case overlappingAllowedIPs(String, String) // tunnel A and B have overlapping IPs
    case conflictingDNS([String])            // active tunnels with different DNS
    case killSwitchBlocking(String)          // tunnel dropped unexpectedly, kill switch is blocking traffic
    case ipFamilyLeak(String, IPFamilyLeak)  // route-all tunnel lets one IP family reach the physical network

    var id: String {
        switch self {
        case .multipleFullTunnels(let names): return "multipleFullTunnels-\(names.joined())"
        case .overlappingAllowedIPs(let a, let b): return "overlappingIPs-\(a)-\(b)"
        case .conflictingDNS(let names): return "conflictingDNS-\(names.joined())"
        case .killSwitchBlocking(let name): return "killSwitchBlocking-\(name)"
        case .ipFamilyLeak(let name, let leak): return "ipFamilyLeak-\(name)-\(leak.family.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .multipleFullTunnels: return "Multiple Full Tunnels"
        case .overlappingAllowedIPs: return "Overlapping Routes"
        case .conflictingDNS: return "DNS Conflict"
        case .killSwitchBlocking: return "Kill Switch Active"
        case .ipFamilyLeak(_, let leak): return "\(leak.family.displayName) Leak"
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
        case .ipFamilyLeak(let name, let leak):
            return "\"\(name)\": \(leak.problem)" + (leak.fixDescription == nil ? "" : " Use the menu bar menu to fix it.")
        }
    }

    var severity: WarningSeverity {
        switch self {
        case .multipleFullTunnels: return .error
        case .overlappingAllowedIPs: return .warning
        case .conflictingDNS: return .info
        case .killSwitchBlocking: return .error
        case .ipFamilyLeak: return .warning
        }
    }
}

enum WarningSeverity {
    case info, warning, error
}
