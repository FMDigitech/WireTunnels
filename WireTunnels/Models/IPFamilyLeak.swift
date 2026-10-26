import Foundation

/// The routing a tunnel was connected with, which can differ from its saved config until it reconnects.
nonisolated struct TunnelRouting: Equatable {
    var address: [String]
    var allowedIPs: [String]
    var dns: [String]
}

nonisolated enum IPFamilyLeakReason: Equatable, Hashable {
    case missingAddress  // routes all of the family but has no address of it, so the routes never install
    case notRouted       // routes all of the other family only, on a network that has this one
    case routeBypassed   // config is right, but the routing table still sends the family elsewhere
}

nonisolated struct IPFamilyLeak: Equatable, Hashable {
    let family: IPFamily
    let reason: IPFamilyLeakReason

    var title: String { "\(family.displayName) is leaking" }

    var problem: String {
        let name = family.displayName
        switch reason {
        case .missingAddress: return "This tunnel has no \(name) address, so \(name) traffic goes around it."
        case .notRouted: return "This tunnel does not route \(name), and this network has \(name), so \(name) traffic goes around it."
        case .routeBypassed: return "The tunnel is set to route all \(name) traffic, but macOS sends it around the tunnel."
        }
    }

    var fixDescription: String? {
        let name = family.displayName
        switch reason {
        case .missingAddress: return "The fix disables \(name) for this tunnel by adding a placeholder \(name) address."
        case .notRouted: return "The fix disables \(name) for this tunnel by routing it into the tunnel with a placeholder address."
        case .routeBypassed: return nil
        }
    }
}

nonisolated struct IPFamilyLeakInput {
    let id: UUID
    let routing: TunnelRouting
    let acknowledged: Bool
}

/// A leak is traffic reaching the physical network while a route-all tunnel is up.
/// Traffic carried by another connected tunnel is not a leak. Acknowledging a tunnel
/// silences its warning (`warnings(from:connected:)`), not the facts its label shows.
nonisolated enum IPFamilyLeakDetector {
    static func leaks(connected: [IPFamilyLeakInput], physicalFamilies: Set<IPFamily>,
                      routeBypassedFamilies: Set<IPFamily>, killSwitchArmed: Bool) -> [UUID: [IPFamilyLeak]] {
        // The kill switch's pf rules drop everything outside the tunnel interfaces.
        guard !killSwitchArmed else { return [:] }
        func routesAll(_ family: IPFamily, _ input: IPFamilyLeakInput) -> Bool {
            IPFamilyRouting.routesAll(family, allowedIPs: input.routing.allowedIPs)
        }
        func hasAddress(_ family: IPFamily, _ input: IPFamilyLeakInput) -> Bool {
            IPFamilyRouting.hasAddress(family, in: input.routing.address)
        }
        let covered = Set(IPFamily.allCases.filter { family in
            connected.contains { routesAll(family, $0) && hasAddress(family, $0) }
        })

        var result: [UUID: [IPFamilyLeak]] = [:]
        for input in connected {
            var leaks: [IPFamilyLeak] = []
            for family in IPFamily.allCases {
                let other: IPFamily = family == .ipv4 ? .ipv6 : .ipv4
                if routesAll(family, input) {
                    if !hasAddress(family, input) {
                        if !covered.contains(family) { leaks.append(IPFamilyLeak(family: family, reason: .missingAddress)) }
                    } else if routeBypassedFamilies.contains(family) {
                        leaks.append(IPFamilyLeak(family: family, reason: .routeBypassed))
                    }
                } else if routesAll(other, input), physicalFamilies.contains(family), !covered.contains(family) {
                    leaks.append(IPFamilyLeak(family: family, reason: .notRouted))
                }
            }
            if !leaks.isEmpty { result[input.id] = leaks }
        }
        return result
    }

    static func warnings(from leaks: [UUID: [IPFamilyLeak]], connected: [IPFamilyLeakInput]) -> [UUID: [IPFamilyLeak]] {
        let acknowledged = Set(connected.filter(\.acknowledged).map(\.id))
        return leaks.filter { !acknowledged.contains($0.key) }
    }

    /// What a route-all tunnel really carries, or nil when it routes neither family in full.
    static func routeLabel(allowedIPs: [String], leaks: [IPFamilyLeak]) -> String? {
        let routed = IPFamilyRouting.routedAllFamilies(allowedIPs: allowedIPs).subtracting(leaks.map(\.family))
        if routed == [.ipv4, .ipv6] { return "All traffic (IPv4+IPv6)" }
        if routed == [.ipv4] { return "All IPv4 traffic" }
        if routed == [.ipv6] { return "All IPv6 traffic" }
        return nil
    }
}
