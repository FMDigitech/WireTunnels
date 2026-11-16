import Darwin
import Foundation

/// DNS servers a profile can use. Addresses are the providers' published anycast resolvers.
struct DNSPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let servers: [String]

    static let all = [
        DNSPreset(id: "cloudflare", name: "Cloudflare",
                  servers: ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]),
        DNSPreset(id: "quad9", name: "Quad9",
                  servers: ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]),
        DNSPreset(id: "google", name: "Google",
                  servers: ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]),
    ]
}

/// A tunnel a profile turns on or off when it becomes the active one.
struct ProfileTunnelAction: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case connect, disconnect
        var displayName: String { self == .connect ? "Connect" : "Disconnect" }
    }
    var tunnelID: UUID
    var kind: Kind
    var id: UUID { tunnelID }
}

/// What WireTunnels does on a network: which DNS servers to use, which tunnels to turn on or off and
/// which Shortcut to run. Profiles are global, unlike a tunnel's own On-Demand rule.
struct NetworkProfile: Codable, Equatable, Hashable, Identifiable {
    static let maxDNSServers = 8

    var id = UUID()
    var name: String
    var isEnabled = true
    /// Where the profile applies. Its own `enabled` flag is ignored: `isEnabled` decides.
    var match = AutoConnectNetworkMatch(enabled: true, interface: .wifi)
    /// Empty leaves the system DNS alone.
    var dnsServers: [String] = []
    /// A Shortcuts name, run once when this profile becomes the active one.
    var shortcutName: String? = nil
    /// Tunnels to connect or disconnect once, when this profile becomes the active one. At most one
    /// action per tunnel. A tunnel's own On-Demand rule can still override it on the next network change.
    var tunnelActions: [ProfileTunnelAction] = []
    /// The proxy to set on the primary network service. nil leaves the system's proxy alone.
    var proxy: ProxySettings? = nil

    init(id: UUID = UUID(), name: String, isEnabled: Bool = true,
         match: AutoConnectNetworkMatch = AutoConnectNetworkMatch(enabled: true, interface: .wifi),
         dnsServers: [String] = [], shortcutName: String? = nil, tunnelActions: [ProfileTunnelAction] = [],
         proxy: ProxySettings? = nil) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.match = match
        self.dnsServers = dnsServers
        self.shortcutName = shortcutName
        self.tunnelActions = tunnelActions
        self.proxy = proxy
    }

    private enum CodingKeys: String, CodingKey { case id, name, isEnabled, match, dnsServers, shortcutName, tunnelActions, proxy }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        match = try container.decodeIfPresent(AutoConnectNetworkMatch.self, forKey: .match)
            ?? AutoConnectNetworkMatch(enabled: true, interface: .wifi)
        dnsServers = try container.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
        shortcutName = try container.decodeIfPresent(String.self, forKey: .shortcutName)
        tunnelActions = try container.decodeIfPresent([ProfileTunnelAction].self, forKey: .tunnelActions) ?? []
        proxy = try container.decodeIfPresent(ProxySettings.self, forKey: .proxy)
    }

    /// DNS server addresses from text separated by commas or spaces, or nil when any entry is not an
    /// IP address. Names are refused: a lookup cannot happen before DNS works.
    static func parseDNSServers(_ text: String) -> [String]? {
        let servers = text.split { $0 == "," || $0.isWhitespace }.map(String.init)
        guard servers.count <= maxDNSServers else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        for server in servers where inet_pton(AF_INET, server, &v4) != 1 && inet_pton(AF_INET6, server, &v6) != 1 {
            return nil
        }
        return servers
    }
}

enum NetworkProfileResolver {
    /// The earlier enabled profile that matches every network `profile` matches, so `profile` can never be
    /// the first match. shortcut: Ethernet subnets are compared as written, not by containment.
    static func shadowingProfile(of profile: NetworkProfile, in profiles: [NetworkProfile]) -> NetworkProfile? {
        guard profile.isEnabled, let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return nil }
        func covers(_ upper: AutoConnectNetworkMatch, _ lower: AutoConnectNetworkMatch) -> Bool {
            func list(_ above: [String], _ below: [String]) -> Bool {
                above.isEmpty || (!below.isEmpty && Set(below).isSubset(of: Set(above)))
            }
            if lower.interface != .ethernet {
                guard upper.interface != .ethernet, list(upper.wifiSSIDs, lower.wifiSSIDs) else { return false }
            }
            if lower.interface != .wifi {
                guard upper.interface != .wifi, list(upper.ethernetSubnets, lower.ethernetSubnets) else { return false }
            }
            return true
        }
        return profiles[..<index].first { $0.isEnabled && covers($0.match, profile.match) }
    }

    /// The first enabled profile that matches the current network, in list order.
    static func firstMatch(in profiles: [NetworkProfile], isOnEthernet: Bool, ethernetAddresses: [String],
                           isOnWiFi: Bool, currentSSID: String?) -> NetworkProfile? {
        profiles.first { profile in
            guard profile.isEnabled else { return false }
            var match = profile.match
            match.enabled = true
            return AutoConnectNetworkMatcher.matches(match, isOnEthernet: isOnEthernet,
                                                     ethernetAddresses: ethernetAddresses,
                                                     isOnWiFi: isOnWiFi, currentSSID: currentSSID)
        }
    }
}
