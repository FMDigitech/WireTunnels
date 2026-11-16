import Foundation
import Darwin

// The network doctor: finds other VPN software and network configuration that fights with the
// active WireTunnels tunnels. Everything here is pure and works on a snapshot, so it can be tested
// without touching the machine. Collecting the snapshot is `NetworkConflictScanner`.

/// A network prefix with its host bits cleared.
nonisolated struct RoutePrefix: Equatable, Hashable {
    let family: IPFamily
    let bytes: [UInt8]
    let length: Int

    init?(family: IPFamily, bytes: [UInt8], length: Int) {
        guard bytes.count == (family == .ipv4 ? 4 : 16), (0...bytes.count * 8).contains(length) else { return nil }
        var masked = bytes
        for index in masked.indices {
            let kept = max(0, min(8, length - index * 8))
            masked[index] &= kept == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - kept))
        }
        self.family = family
        self.bytes = masked
        self.length = length
    }

    func contains(_ other: RoutePrefix) -> Bool {
        guard family == other.family, length <= other.length else { return false }
        return RoutePrefix(family: family, bytes: other.bytes, length: length)?.bytes == bytes
    }

    func overlaps(_ other: RoutePrefix) -> Bool { contains(other) || other.contains(self) }

    var isDefault: Bool { length == 0 }

    /// The two halves that wg-quick and most VPNs install instead of replacing the default route.
    var isDefaultHalf: Bool { length == 1 }

    var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let af = family == .ipv4 ? AF_INET : AF_INET6
        let text = bytes.withUnsafeBytes { inet_ntop(af, $0.baseAddress, &buffer, socklen_t(buffer.count)) != nil }
            ? String(cString: buffer) : "?"
        return "\(text)/\(length)"
    }

    /// Prefixes no VPN should be blamed for: loopback, link-local, multicast, broadcast.
    var isInfrastructure: Bool {
        let special: [(IPFamily, [UInt8], Int)] = [
            (.ipv4, [127, 0, 0, 0], 8), (.ipv4, [169, 254, 0, 0], 16),
            (.ipv4, [224, 0, 0, 0], 4), (.ipv4, [240, 0, 0, 0], 4),
            (.ipv6, [0xfe, 0x80] + [UInt8](repeating: 0, count: 14), 10),
            (.ipv6, [0xff] + [UInt8](repeating: 0, count: 15), 8),
            (.ipv6, [UInt8](repeating: 0, count: 15) + [1], 128),
        ]
        return special.contains { family, bytes, length in
            guard family == self.family, let block = RoutePrefix(family: family, bytes: bytes, length: length) else { return false }
            return block.contains(self)
        }
    }

    /// Reads one `netstat -rn` destination: "default", "10.10/24", "127", "169.254", "2000::/3",
    /// "fe80::%utun4/64". Abbreviated IPv4 networks carry their length in the number of octets.
    static func parse(netstatDestination text: String, family: IPFamily) -> RoutePrefix? {
        if text == "default" { return RoutePrefix(family: family, bytes: [UInt8](repeating: 0, count: family == .ipv4 ? 4 : 16), length: 0) }
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let address = String(parts[0].split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let explicit: Int? = parts.count == 2 ? Int(parts[1]) : nil
        if parts.count == 2 && explicit == nil { return nil }
        switch family {
        case .ipv4:
            let octets = address.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(octets.count) else { return nil }
            var bytes: [UInt8] = []
            for octet in octets {
                guard !octet.isEmpty, octet.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let value = UInt8(octet) else { return nil }
                bytes.append(value)
            }
            let length = explicit ?? bytes.count * 8
            while bytes.count < 4 { bytes.append(0) }
            return RoutePrefix(family: .ipv4, bytes: bytes, length: length)
        case .ipv6:
            var v6 = in6_addr()
            guard !address.isEmpty, inet_pton(AF_INET6, address, &v6) == 1 else { return nil }
            return RoutePrefix(family: .ipv6, bytes: withUnsafeBytes(of: &v6) { Array($0) }, length: explicit ?? 128)
        }
    }
}

nonisolated struct RoutingTableEntry: Equatable {
    let prefix: RoutePrefix
    let interface: String
    /// Interface-scoped copies (flag I) only answer traffic bound to that interface.
    let isScoped: Bool
}

nonisolated enum NetstatRoutes {
    /// Parses `netstat -rn -f inet` or `-f inet6`: Destination, Gateway, Flags, Netif, Expire.
    static func parse(_ output: String, family: IPFamily) -> [RoutingTableEntry] {
        var entries: [RoutingTableEntry] = []
        var inTable = false
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if fields.first == "Destination" { inTable = true; continue }
            guard inTable, fields.count >= 4,
                  let prefix = RoutePrefix.parse(netstatDestination: fields[0], family: family) else { continue }
            entries.append(RoutingTableEntry(prefix: prefix, interface: fields[3], isScoped: fields[2].contains("I")))
        }
        return entries
    }

    /// Interfaces that carry all traffic of a family: a default route, or both /1 halves.
    /// Scoped routes are ignored because only traffic bound to that interface uses them.
    static func internetCarriers(_ routes: [RoutingTableEntry], family: IPFamily) -> [String] {
        let live = routes.filter { !$0.isScoped && $0.prefix.family == family }
        var carriers = Set(live.filter { $0.prefix.isDefault }.map { $0.interface })
        let halves = Dictionary(grouping: live.filter { $0.prefix.isDefaultHalf }, by: { $0.interface })
        for (interface, entries) in halves where Set(entries.map { $0.prefix.bytes[0] >> 7 }).count == 2 {
            carriers.insert(interface)
        }
        return carriers.sorted()
    }
}

nonisolated struct DNSResolver: Equatable {
    var domains: [String] = []
    var nameservers: [String] = []
    var interface: String?
    var isMulticast = false
    var isScoped = false
}

nonisolated enum ScutilDNS {
    /// Parses `scutil --dns`. The section after "for scoped queries" holds per-interface copies.
    static func parse(_ output: String) -> [DNSResolver] {
        var resolvers: [DNSResolver] = []
        var current: DNSResolver?
        var scoped = false
        func flush() {
            if let current { resolvers.append(current) }
            current = nil
        }
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration") {
                flush()
                scoped = line.contains("scoped")
            } else if line.hasPrefix("resolver #") {
                flush()
                current = DNSResolver(isScoped: scoped)
            } else if current != nil, let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if key.hasPrefix("nameserver[") {
                    current?.nameservers.append(value)
                } else if key == "domain" {
                    current?.domains.append(value)
                } else if key == "options" && value.split(separator: " ").contains("mdns") {
                    current?.isMulticast = true
                } else if key == "if_index" {
                    // "17 (utun4)"
                    if let open = value.firstIndex(of: "("), let close = value.firstIndex(of: ")"), open < close {
                        current?.interface = String(value[value.index(after: open)..<close])
                    }
                }
            }
        }
        flush()
        return resolvers
    }
}

nonisolated struct NetworkInterfaceInfo: Equatable {
    let name: String
    let addresses: [String]
}

/// Software that installs its own tunnel, recognised by process name. Names were taken from the
/// vendors' documentation, not checked against every release, so a miss is possible.
nonisolated struct KnownVPNProduct: Equatable {
    let name: String
    let processNames: [String]

    static let all: [KnownVPNProduct] = [
        KnownVPNProduct(name: "Tailscale", processNames: ["tailscaled", "tailscale"]),
        KnownVPNProduct(name: "NetBird", processNames: ["netbird"]),
        KnownVPNProduct(name: "Mullvad VPN", processNames: ["mullvad-daemon", "mullvad vpn"]),
        KnownVPNProduct(name: "Cloudflare WARP", processNames: ["warp-svc", "cloudflare warp"]),
        KnownVPNProduct(name: "Cisco Secure Client / AnyConnect", processNames: ["vpnagentd", "cisco secure client", "cisco anyconnect secure mobility client"]),
        KnownVPNProduct(name: "GlobalProtect", processNames: ["pangps", "globalprotect"]),
        KnownVPNProduct(name: "Zscaler", processNames: ["zscalertunnel", "zscaler"]),
        KnownVPNProduct(name: "OpenVPN", processNames: ["openvpn"]),
        KnownVPNProduct(name: "ZeroTier", processNames: ["zerotier-one"]),
        KnownVPNProduct(name: "Proton VPN", processNames: ["proton vpn", "protonvpn"]),
        KnownVPNProduct(name: "NordVPN", processNames: ["nordvpn", "nordvpnd"]),
        KnownVPNProduct(name: "FortiClient", processNames: ["forticlient", "fctservctl"]),
    ]

    /// `ps -axo comm=` prints the executable's path. Any component can name the product: the daemon
    /// itself ("tailscaled") or the app that holds it ("Mullvad VPN.app/Contents/...").
    static func detect(inProcessList output: String) -> [KnownVPNProduct] {
        var names = Set<String>()
        for line in output.components(separatedBy: .newlines) {
            for component in line.split(separator: "/") {
                var name = component.trimmingCharacters(in: .whitespaces).lowercased()
                if name.hasSuffix(".app") { name.removeLast(4) }
                names.insert(name)
            }
        }
        return all.filter { product in product.processNames.contains { names.contains($0) } }
    }
}

nonisolated struct OwnTunnelState: Equatable {
    let name: String
    /// The utun the tunnel runs on, nil until a status refresh has mapped it.
    let interface: String?
    let allowedIPs: [String]
    let dns: [String]
    let killSwitchArmed: Bool
    /// The tunnel's own addresses without prefix length. The kernel puts them on its utun, so they
    /// find the interface when a status refresh has not mapped it yet.
    var addresses: [String] = []
}

nonisolated struct NetworkSnapshot: Equatable {
    var interfaces: [NetworkInterfaceInfo]
    var routes: [RoutingTableEntry]
    var resolvers: [DNSResolver]
    var products: [KnownVPNProduct]
    var ownTunnels: [OwnTunnelState]
}

nonisolated enum FindingSeverity: Int, Comparable {
    case info, warning, error
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated struct NetworkFinding: Identifiable, Equatable {
    let id: String
    let severity: FindingSeverity
    let title: String
    let detail: String
    let advice: String?
}

nonisolated enum NetworkConflictAnalyzer {
    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]

    static func isTunnelInterface(_ name: String) -> Bool { tunnelPrefixes.contains { name.hasPrefix($0) } }

    private static func isLinkLocal(_ address: String) -> Bool {
        let lower = address.lowercased()
        return lower.hasPrefix("fe80:") || lower.hasPrefix("169.254.")
    }

    /// Tunnel interfaces that are neither ours nor idle: an address that is not link-local, or a real route.
    static func foreignTunnelInterfaces(_ snapshot: NetworkSnapshot, own: Set<String>) -> [String] {
        let withAddress = snapshot.interfaces.filter { info in
            isTunnelInterface(info.name) && !own.contains(info.name) && info.addresses.contains { !isLinkLocal($0) }
        }.map { $0.name }
        let withRoutes = snapshot.routes.filter { route in
            isTunnelInterface(route.interface) && !own.contains(route.interface)
                && !route.isScoped && !route.prefix.isInfrastructure
        }.map { $0.interface }
        return Array(Set(withAddress + withRoutes)).sorted()
    }

    /// Fills in the utun of tunnels whose interface is not known yet, from the addresses they were given.
    static func resolvingInterfaces(_ snapshot: NetworkSnapshot) -> [OwnTunnelState] {
        snapshot.ownTunnels.map { tunnel in
            guard tunnel.interface.map(isTunnelInterface) != true, !tunnel.addresses.isEmpty else { return tunnel }
            let matches = snapshot.interfaces.filter { info in
                isTunnelInterface(info.name) && info.addresses.contains { tunnel.addresses.contains($0) }
            }
            guard matches.count == 1 else { return tunnel }
            return OwnTunnelState(name: tunnel.name, interface: matches[0].name, allowedIPs: tunnel.allowedIPs,
                                  dns: tunnel.dns, killSwitchArmed: tunnel.killSwitchArmed, addresses: tunnel.addresses)
        }
    }

    static func analyze(_ snapshot: NetworkSnapshot) -> [NetworkFinding] {
        var findings: [NetworkFinding] = []
        let tunnels = resolvingInterfaces(snapshot)
        // Without a utun for every active tunnel an interface cannot be called foreign.
        let ownershipKnown = tunnels.allSatisfy { $0.interface.map(isTunnelInterface) == true }
        let own = Set(tunnels.compactMap { $0.interface })
        let foreign = ownershipKnown ? foreignTunnelInterfaces(snapshot, own: own) : []
        // One running product is the likely owner; with a few, say which ones it could be; with
        // many, naming any would be a guess.
        let attribution: String? = switch snapshot.products.count {
        case 0: nil
        case 1: "probably \(snapshot.products[0].name)"
        case 2...3: "one of \(snapshot.products.map { $0.name }.joined(separator: ", "))"
        default: nil
        }

        for product in snapshot.products {
            findings.append(NetworkFinding(
                id: "product-\(product.name)", severity: .info,
                title: "\(product.name) is running",
                detail: "It can add its own routes and DNS settings, and these can override a WireTunnels tunnel.",
                advice: tunnels.isEmpty ? nil : "If traffic or DNS misbehaves, disconnect \(product.name) and compare."))
        }

        func describe(_ interface: String) -> String {
            attribution.map { "\(interface) (\($0))" } ?? interface
        }

        guard ownershipKnown else {
            if !tunnels.isEmpty {
                findings.append(NetworkFinding(
                    id: "ownership-unknown", severity: .info,
                    title: "Tunnel interfaces not mapped yet",
                    detail: "Not every active tunnel has a known interface, so other VPNs cannot be told apart from yours.",
                    advice: "Scan again in a few seconds."))
            }
            return sorted(findings)
        }

        for family in IPFamily.allCases {
            let carriers = NetstatRoutes.internetCarriers(snapshot.routes, family: family)
            let fullTunnels = tunnels.filter { tunnel in
                IPFamilyRouting.routesAll(family, allowedIPs: tunnel.allowedIPs)
            }
            let foreignCarriers = carriers.filter { foreign.contains($0) }
            if fullTunnels.isEmpty {
                for interface in foreignCarriers {
                    findings.append(NetworkFinding(
                        id: "default-\(family.rawValue)-\(interface)", severity: .info,
                        title: "\(describe(interface)) carries all \(family.displayName) traffic",
                        detail: "Another VPN routes all \(family.displayName) traffic. Connecting a full-tunnel WireTunnels tunnel now would compete with it.",
                        advice: nil))
                }
                continue
            }
            let missing = fullTunnels.filter { tunnel in tunnel.interface.map { !carriers.contains($0) } ?? false }
            for tunnel in missing {
                let by = carriers.map(describe).joined(separator: ", ")
                findings.append(NetworkFinding(
                    id: "takeover-\(family.rawValue)-\(tunnel.name)", severity: .error,
                    title: "\(family.displayName) traffic bypasses \"\(tunnel.name)\"",
                    detail: carriers.isEmpty
                        ? "\"\(tunnel.name)\" routes all \(family.displayName) traffic, but the routing table has no catch-all route."
                        : "\"\(tunnel.name)\" routes all \(family.displayName) traffic, but the routing table sends it through \(by).",
                    advice: foreignCarriers.isEmpty ? "Reconnect the tunnel." : "Disconnect the other VPN, or reconnect \"\(tunnel.name)\" after it."))
            }
            if foreignCarriers.count > 0 && missing.isEmpty && !carriers.isEmpty {
                let both = foreignCarriers.map(describe).joined(separator: ", ")
                findings.append(NetworkFinding(
                    id: "shared-default-\(family.rawValue)", severity: .warning,
                    title: "Two VPNs claim all \(family.displayName) traffic",
                    detail: "\(both) and your tunnel both install a catch-all route. Which one wins depends on the order they connected.",
                    advice: "Use only one full-tunnel VPN at a time."))
            }
        }

        // Specific routes that both sides want.
        for tunnel in tunnels {
            guard let interface = tunnel.interface else { continue }
            let mine = snapshot.routes.filter { $0.interface == interface && !$0.isScoped && !$0.prefix.isDefault
                && !$0.prefix.isDefaultHalf && !$0.prefix.isInfrastructure }
            for other in foreign {
                let theirs = snapshot.routes.filter { $0.interface == other && !$0.isScoped && !$0.prefix.isDefault
                    && !$0.prefix.isDefaultHalf && !$0.prefix.isInfrastructure }
                let clashes = mine.flatMap { a in theirs.filter { a.prefix.overlaps($0.prefix) }.map { (a.prefix, $0.prefix) } }
                guard let example = clashes.first else { continue }
                let more = clashes.count > 1 ? " and \(clashes.count - 1) more" : ""
                findings.append(NetworkFinding(
                    id: "overlap-\(interface)-\(other)", severity: .warning,
                    title: "Routes overlap with \(describe(other))",
                    detail: "\"\(tunnel.name)\" routes \(example.0.description) and \(other) routes \(example.1.description)\(more). The more specific route wins, so some traffic may leave through the wrong VPN.",
                    advice: "Narrow the AllowedIPs of one of them, or change the subnet one side uses."))
            }
        }

        // DNS: who answers for names that have no special domain.
        let activeDNS = tunnels.filter { !$0.dns.isEmpty }
        let defaultResolver = snapshot.resolvers.first { !$0.isScoped && !$0.isMulticast && $0.domains.isEmpty && !$0.nameservers.isEmpty }
        let fullAny = tunnels.contains { tunnel in IPFamily.allCases.contains { IPFamilyRouting.routesAll($0, allowedIPs: tunnel.allowedIPs) } }
        if fullAny, let defaultResolver {
            let ours = Set(activeDNS.flatMap { WireGuardDNS.servers($0.dns) })
            let theirs = Set(defaultResolver.nameservers)
            if ours.isEmpty {
                findings.append(NetworkFinding(
                    id: "dns-outside", severity: .warning,
                    title: "DNS queries are not sent through the tunnel",
                    detail: "A full-tunnel VPN is connected but it sets no DNS servers. Names are looked up by \(theirs.sorted().joined(separator: ", ")), which the local network chooses, so the sites you visit are visible to it.",
                    advice: "Add a DNS line to the tunnel, or pick DNS servers in a network profile."))
            } else if ours.isDisjoint(with: theirs) {
                findings.append(NetworkFinding(
                    id: "dns-overridden", severity: .warning,
                    title: "The tunnel's DNS is not the one in use",
                    detail: "Tunnel DNS is \(ours.sorted().joined(separator: ", ")), but macOS resolves names with \(theirs.sorted().joined(separator: ", "))\(defaultResolver.interface.map { " (via \($0))" } ?? "").",
                    advice: "Another VPN, a profile or a DNS app may have replaced it."))
            }
        }
        for resolver in snapshot.resolvers where !resolver.isMulticast {
            guard let interface = resolver.interface, foreign.contains(interface) else { continue }
            let scope = resolver.domains.isEmpty ? "all names" : resolver.domains.joined(separator: ", ")
            findings.append(NetworkFinding(
                id: "dns-foreign-\(interface)-\(scope)", severity: resolver.domains.isEmpty && !resolver.isScoped ? .warning : .info,
                title: "\(describe(interface)) answers DNS for \(scope)",
                detail: "Servers: \(resolver.nameservers.joined(separator: ", ")).",
                advice: resolver.domains.isEmpty && !resolver.isScoped ? "It competes with the DNS of your tunnels." : nil))
        }
        // Dedupe the entries scoped/unscoped copies of one resolver produce.
        findings = Dictionary(grouping: findings, by: { $0.id }).compactMap { $0.value.first }

        if tunnels.contains(where: { $0.killSwitchArmed }), !foreign.isEmpty || !snapshot.products.isEmpty {
            findings.append(NetworkFinding(
                id: "killswitch-foreign", severity: .warning,
                title: "The kill switch blocks other VPNs",
                detail: "While a kill switch is armed, the firewall drops all traffic except your tunnels and their endpoints, so another VPN cannot connect or carry traffic.",
                advice: "Turn off the kill switch of the tunnel before using the other VPN."))
        }
        return sorted(findings)
    }

    private static func sorted(_ findings: [NetworkFinding]) -> [NetworkFinding] {
        findings.sorted { ($0.severity, $1.id) > ($1.severity, $0.id) }
    }
}
