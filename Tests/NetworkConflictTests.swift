import Foundation

@main
struct NetworkConflictTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    static func route(_ destination: String, _ interface: String, scoped: Bool = false, family: IPFamily = .ipv4) -> RoutingTableEntry {
        RoutingTableEntry(prefix: RoutePrefix.parse(netstatDestination: destination, family: family)!, interface: interface, isScoped: scoped)
    }

    static func tunnel(_ name: String = "work", interface: String? = "utun5", allowed: [String] = ["0.0.0.0/0"],
                       dns: [String] = [], killSwitch: Bool = false) -> OwnTunnelState {
        OwnTunnelState(name: name, interface: interface, allowedIPs: allowed, dns: dns, killSwitchArmed: killSwitch)
    }

    static func snapshot(routes: [RoutingTableEntry] = [], interfaces: [NetworkInterfaceInfo] = [], resolvers: [DNSResolver] = [],
                         products: [KnownVPNProduct] = [], tunnels: [OwnTunnelState]) -> NetworkSnapshot {
        NetworkSnapshot(interfaces: interfaces, routes: routes, resolvers: resolvers, products: products, ownTunnels: tunnels)
    }

    static func ids(_ findings: [NetworkFinding]) -> [String] { findings.map(\.id) }

    static func main() {
        // Destinations as netstat prints them.
        func prefix(_ text: String, _ family: IPFamily = .ipv4) -> String? {
            RoutePrefix.parse(netstatDestination: text, family: family)?.description
        }
        check(prefix("default") == "0.0.0.0/0", "default")
        check(prefix("10.10/24") == "10.10.0.0/24", "explicit length with abbreviated octets")
        check(prefix("127") == "127.0.0.0/8", "one octet means a /8")
        check(prefix("169.254") == "169.254.0.0/16", "two octets mean a /16")
        check(prefix("0/1") == "0.0.0.0/1" && prefix("128.0/1") == "128.0.0.0/1", "the halves of the default route")
        check(prefix("10.10.0.1") == "10.10.0.1/32", "a full address is a host")
        check(prefix("10.10.0.77/24") == "10.10.0.0/24", "host bits are cleared")
        check(prefix("fe80::%lo0/64", .ipv6) == "fe80::/64", "an IPv6 scope suffix is dropped")
        check(prefix("2000::/3", .ipv6) == "2000::/3" && prefix("default", .ipv6) == "::/0", "IPv6 destinations")
        check(prefix("not-an-address") == nil && prefix("10.0.0.256") == nil && prefix("10.0/x") == nil, "garbage is rejected")
        check(RoutePrefix.parse(netstatDestination: "224.0.0/4", family: .ipv4)!.isInfrastructure, "multicast is infrastructure")
        check(RoutePrefix.parse(netstatDestination: "169.254", family: .ipv4)!.isInfrastructure, "link-local is infrastructure")
        check(!RoutePrefix.parse(netstatDestination: "10.0.0.0/8", family: .ipv4)!.isInfrastructure, "private space is not")

        let a = RoutePrefix.parse(netstatDestination: "10.0.0.0/8", family: .ipv4)!
        let b = RoutePrefix.parse(netstatDestination: "10.1.0.0/16", family: .ipv4)!
        let c = RoutePrefix.parse(netstatDestination: "192.168.0.0/16", family: .ipv4)!
        check(a.overlaps(b) && b.overlaps(a) && !a.overlaps(c), "overlap is symmetric and exact")

        // A routing table in the format of `netstat -rn -f inet`.
        let table = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            10.10.0.1          UGScg                 en0
        default            link#17            UCSIg               utun4
        0/1                link#17            UCS                 utun4
        128.0/1            link#17            UCS                 utun4
        10.10/24           link#4             UCS                   en0      !
        10.10.0.1          bc:24:11:d5:f4:33  UHLWIir               en0   1169
        100.64/10          link#18            UCS                 utun7
        127                127.0.0.1          UCS                   lo0
        169.254            link#4             UCS                   en0      !
        224.0.0/4          link#4             UmCS                  en0      !
        255.255.255.255/32 link#4             UCS                   en0      !
        """
        let routes = NetstatRoutes.parse(table, family: .ipv4)
        check(routes.count == 11, "every route line is read, got \(routes.count)")
        check(routes.filter(\.isScoped).map(\.interface) == ["utun4", "en0"], "scoped routes carry the I flag")
        check(NetstatRoutes.internetCarriers(routes, family: .ipv4) == ["en0", "utun4"],
              "a default route and both halves each make a carrier; the scoped default does not")
        check(NetstatRoutes.internetCarriers([route("0/1", "utun4")], family: .ipv4).isEmpty, "one half is not a catch-all")
        check(NetstatRoutes.internetCarriers([route("default", "utun9", scoped: true)], family: .ipv4).isEmpty,
              "an interface-scoped default route carries nothing by itself")
        check(NetstatRoutes.internetCarriers([route("default", "utun9", scoped: true), route("default", "en0")], family: .ipv4) == ["en0"],
              "only the unscoped default route counts")
        check(NetstatRoutes.parse("", family: .ipv4).isEmpty, "empty output has no routes")

        // scutil --dns
        let dns = """
        DNS configuration

        resolver #1
          nameserver[0] : 10.0.0.1
          flags    : Request A records
          reach    : 0x00000002 (Reachable)

        resolver #2
          domain   : local
          options  : mdns
          timeout  : 5
          order    : 300000

        resolver #3
          domain   : corp.example
          nameserver[0] : 100.100.100.100
          if_index : 18 (utun7)
          flags    : Scoped, Request A records

        DNS configuration (for scoped queries)

        resolver #1
          nameserver[0] : 10.0.0.1
          if_index : 4 (en0)
        """
        let resolvers = ScutilDNS.parse(dns)
        check(resolvers.count == 4, "four resolvers, got \(resolvers.count)")
        check(resolvers[0].nameservers == ["10.0.0.1"] && resolvers[0].domains.isEmpty && !resolvers[0].isScoped, "the default resolver")
        check(resolvers[1].isMulticast, "mdns resolvers are marked")
        check(resolvers[2].domains == ["corp.example"] && resolvers[2].interface == "utun7", "an interface-bound split resolver")
        check(resolvers[3].isScoped && resolvers[3].interface == "en0", "the scoped section is flagged")

        // Product detection.
        let processes = "/sbin/launchd\n/Applications/Tailscale.app/Contents/MacOS/Tailscale\n/usr/local/bin/tailscaled\n/usr/sbin/cfprefsd\n"
        check(KnownVPNProduct.detect(inProcessList: processes).map(\.name) == ["Tailscale"], "tailscale is found by process name")
        check(KnownVPNProduct.detect(inProcessList: "/usr/sbin/cfprefsd\n/bin/zsh\n").isEmpty, "ordinary processes are not VPNs")

        // Products are found by the app that holds a daemon, and several candidates are all named.
        let bundled = "/Applications/Cloudflare WARP.app/Contents/Resources/CloudflareWARP\n/Applications/Mullvad VPN.app/Contents/MacOS/mullvad-vpn-helper\n"
        check(Set(KnownVPNProduct.detect(inProcessList: bundled).map(\.name)) == ["Cloudflare WARP", "Mullvad VPN"],
              "a helper inside an app bundle is found by the bundle's name")
        check(KnownVPNProduct.detect(inProcessList: "/Users/me/tailscale-notes/editor\n").isEmpty, "only whole path components match")

        let foreignInterface = NetworkInterfaceInfo(name: "utun7", addresses: ["100.64.0.5", "fe80::1"])
        let tailscale = KnownVPNProduct.all.first { $0.name == "Tailscale" }!

        // Nothing wrong: our full tunnel owns the internet, a mesh VPN holds only its own range.
        let calm = snapshot(
            routes: [route("0/1", "utun5"), route("128.0/1", "utun5"), route("default", "en0"), route("100.64/10", "utun7"),
                     route("10.9.0.0/24", "utun5")],
            interfaces: [foreignInterface, NetworkInterfaceInfo(name: "utun5", addresses: ["10.9.0.2"])],
            products: [tailscale], tunnels: [tunnel(dns: ["10.9.0.1"])])
        check(ids(NetworkConflictAnalyzer.analyze(calm)) == ["product-Tailscale"],
              "a running mesh VPN with its own range is reported, nothing else: \(ids(NetworkConflictAnalyzer.analyze(calm)))")

        // The system's own utuns hold only link-local addresses and are not VPNs.
        let system = snapshot(routes: [route("0/1", "utun5"), route("128.0/1", "utun5")],
                              interfaces: [NetworkInterfaceInfo(name: "utun0", addresses: ["fe80::1"])],
                              tunnels: [tunnel(dns: ["10.9.0.1"])])
        check(NetworkConflictAnalyzer.analyze(system).isEmpty, "idle system utuns are not foreign")
        check(NetworkConflictAnalyzer.foreignTunnelInterfaces(system, own: ["utun5"]).isEmpty,
              "a utun with only a link-local address is idle, not another VPN")
        check(NetworkConflictAnalyzer.foreignTunnelInterfaces(snapshot(interfaces: [foreignInterface], tunnels: []), own: ["utun5"]) == ["utun7"],
              "a utun with a routable address is another VPN")
        check(NetworkConflictAnalyzer.foreignTunnelInterfaces(
            snapshot(routes: [route("172.16.0.0/12", "utun9")], tunnels: []), own: []) == ["utun9"],
              "a utun that holds a real route is another VPN even without an address")
        check(NetworkConflictAnalyzer.foreignTunnelInterfaces(
            snapshot(routes: [route("224.0.0/4", "utun9"), route("169.254", "utun9")], tunnels: []), own: []).isEmpty,
              "multicast and link-local routes do not make a VPN")

        // Another VPN takes over the internet.
        let takeover = snapshot(
            routes: [route("0/1", "utun7"), route("128.0/1", "utun7"), route("default", "en0")],
            interfaces: [foreignInterface], products: [tailscale], tunnels: [tunnel(dns: ["10.9.0.1"])])
        let taken = NetworkConflictAnalyzer.analyze(takeover)
        check(taken.first?.id == "takeover-ipv4-work" && taken.first?.severity == .error, "a takeover is the top finding: \(ids(taken))")
        check(taken.first?.detail.contains("utun7 (probably Tailscale)") == true, "the other interface is named")

        // Two catch-alls at once.
        let shared = snapshot(
            routes: [route("0/1", "utun5"), route("128.0/1", "utun5"), route("0/1", "utun7"), route("128.0/1", "utun7")],
            interfaces: [foreignInterface], tunnels: [tunnel(dns: ["10.9.0.1"])])
        check(ids(NetworkConflictAnalyzer.analyze(shared)) == ["shared-default-ipv4"], "two catch-alls are a conflict")

        // A foreign VPN with the default route while we have no full tunnel is only information.
        let observed = snapshot(routes: [route("default", "utun7")], interfaces: [foreignInterface],
                                tunnels: [tunnel(allowed: ["10.9.0.0/24"], dns: [])])
        let observedFindings = NetworkConflictAnalyzer.analyze(observed)
        check(ids(observedFindings) == ["default-ipv4-utun7"] && observedFindings[0].severity == .info,
              "a foreign catch-all next to a split tunnel is informational: \(ids(observedFindings))")

        // Overlapping specific routes.
        let overlap = snapshot(
            routes: [route("10.0.0.0/8", "utun5"), route("10.1.0.0/16", "utun7"), route("192.168.50.0/24", "utun7")],
            interfaces: [foreignInterface, NetworkInterfaceInfo(name: "utun5", addresses: ["10.0.0.2"])],
            tunnels: [tunnel(allowed: ["10.0.0.0/8"])])
        let overlaps = NetworkConflictAnalyzer.analyze(overlap)
        check(ids(overlaps) == ["overlap-utun5-utun7"] && overlaps[0].detail.contains("10.0.0.0/8")
              && overlaps[0].detail.contains("10.1.0.0/16"), "an overlap names both ranges: \(overlaps)")

        // Without a utun for every tunnel, ownership is unknown and nothing is blamed on others.
        let unknown = snapshot(routes: [route("0/1", "utun7"), route("128.0/1", "utun7")], interfaces: [foreignInterface],
                               tunnels: [tunnel(interface: "work")])
        check(ids(NetworkConflictAnalyzer.analyze(unknown)) == ["ownership-unknown"], "an unmapped tunnel hides foreign findings")

        // DNS.
        func dnsFindings(ours: [String], resolver: [String], viaForeign: Bool = false) -> [String] {
            ids(NetworkConflictAnalyzer.analyze(snapshot(
                routes: [route("0/1", "utun5"), route("128.0/1", "utun5")],
                interfaces: [foreignInterface],
                resolvers: [DNSResolver(domains: [], nameservers: resolver, interface: viaForeign ? "utun7" : nil, isMulticast: false, isScoped: false)],
                tunnels: [tunnel(dns: ours)])))
        }
        check(dnsFindings(ours: [], resolver: ["10.0.0.1"]) == ["dns-outside"], "a full tunnel without DNS leaves lookups outside")
        check(dnsFindings(ours: ["10.9.0.1"], resolver: ["10.0.0.1"]) == ["dns-overridden"], "the tunnel's DNS is replaced")
        check(dnsFindings(ours: ["10.9.0.1"], resolver: ["10.9.0.1"]).isEmpty, "matching DNS is fine")
        check(dnsFindings(ours: ["10.9.0.1", "example.org"], resolver: ["10.9.0.1"]).isEmpty, "search domains in the DNS line are ignored")
        check(Set(dnsFindings(ours: ["10.9.0.1"], resolver: ["100.100.100.100"], viaForeign: true)) == ["dns-overridden", "dns-foreign-utun7-all names"],
              "a foreign default resolver is named")
        let splitOnly = snapshot(routes: [route("10.9.0.0/24", "utun5")], resolvers: [DNSResolver(domains: [], nameservers: ["10.0.0.1"])],
                                 tunnels: [tunnel(allowed: ["10.9.0.0/24"])])
        check(NetworkConflictAnalyzer.analyze(splitOnly).isEmpty, "a split tunnel without DNS is normal")

        // Split-DNS of another VPN for its own domains is not a conflict.
        let split = snapshot(routes: [route("0/1", "utun5"), route("128.0/1", "utun5")], interfaces: [foreignInterface],
                             resolvers: [DNSResolver(domains: ["corp.example"], nameservers: ["100.100.100.100"], interface: "utun7")],
                             tunnels: [tunnel(dns: [])])
        let splitFindings = NetworkConflictAnalyzer.analyze(split)
        check(splitFindings.first { $0.id.hasPrefix("dns-foreign") }?.severity == .info, "domain-scoped DNS is informational")

        // Attribution: one product is "probably", a few are "one of", many are not named.
        func takeoverDetail(_ products: [KnownVPNProduct]) -> String {
            NetworkConflictAnalyzer.analyze(snapshot(
                routes: [route("0/1", "utun7"), route("128.0/1", "utun7")], interfaces: [foreignInterface],
                products: products, tunnels: [tunnel(dns: ["10.9.0.1"])])).first { $0.id.hasPrefix("takeover") }?.detail ?? ""
        }
        let nord = KnownVPNProduct.all.first { $0.name == "NordVPN" }!
        let warp = KnownVPNProduct.all.first { $0.name == "Cloudflare WARP" }!
        let mullvad = KnownVPNProduct.all.first { $0.name == "Mullvad VPN" }!
        check(takeoverDetail([tailscale]).contains("utun7 (probably Tailscale)"), "one product is the likely owner")
        check(takeoverDetail([tailscale, nord]).contains("utun7 (one of Tailscale, NordVPN)"), "two products are both named")
        let many = takeoverDetail([tailscale, nord, warp, mullvad])
        check(many.contains("utun7") && !many.contains("probably") && !many.contains("one of"), "many products are not guessed at")

        // A tunnel whose utun is not mapped yet is found by its own address.
        let unmapped = snapshot(
            routes: [route("0/1", "utun5"), route("128.0/1", "utun5"), route("0/1", "utun7"), route("128.0/1", "utun7")],
            interfaces: [foreignInterface, NetworkInterfaceInfo(name: "utun5", addresses: ["10.9.0.2", "fe80::2"])],
            tunnels: [OwnTunnelState(name: "work", interface: "work", allowedIPs: ["0.0.0.0/0"], dns: ["10.9.0.1"],
                                     killSwitchArmed: false, addresses: ["10.9.0.2"])])
        check(NetworkConflictAnalyzer.resolvingInterfaces(unmapped).first?.interface == "utun5", "the utun is found from the tunnel's address")
        check(ids(NetworkConflictAnalyzer.analyze(unmapped)) == ["shared-default-ipv4"], "findings work without a mapped interface")
        let ambiguous = snapshot(
            interfaces: [NetworkInterfaceInfo(name: "utun5", addresses: ["10.9.0.2"]), NetworkInterfaceInfo(name: "utun6", addresses: ["10.9.0.2"])],
            tunnels: [OwnTunnelState(name: "work", interface: nil, allowedIPs: [], dns: [], killSwitchArmed: false, addresses: ["10.9.0.2"])])
        check(NetworkConflictAnalyzer.resolvingInterfaces(ambiguous).first?.interface == nil, "an address on two interfaces is not guessed")
        let mapped = snapshot(interfaces: [NetworkInterfaceInfo(name: "utun6", addresses: ["10.9.0.2"])],
                              tunnels: [OwnTunnelState(name: "work", interface: "utun5", allowedIPs: [], dns: [], killSwitchArmed: false, addresses: ["10.9.0.2"])])
        check(NetworkConflictAnalyzer.resolvingInterfaces(mapped).first?.interface == "utun5", "a known interface is never replaced")

        // The kill switch blocks other VPNs.
        let killed = snapshot(routes: [route("0/1", "utun5"), route("128.0/1", "utun5")], products: [tailscale],
                              tunnels: [tunnel(dns: ["10.9.0.1"], killSwitch: true)])
        check(ids(NetworkConflictAnalyzer.analyze(killed)).contains("killswitch-foreign"), "a kill switch with another VPN around is flagged")
        check(!ids(NetworkConflictAnalyzer.analyze(snapshot(routes: [route("0/1", "utun5"), route("128.0/1", "utun5")],
                                                           tunnels: [tunnel(dns: ["10.9.0.1"], killSwitch: true)]))).contains("killswitch-foreign"),
              "a kill switch alone is not")

        // IPv6 half-routes are recognised too.
        let v6 = [route("::/1", "utun5", family: .ipv6), route("8000::/1", "utun5", family: .ipv6)]
        check(NetstatRoutes.internetCarriers(v6, family: .ipv6) == ["utun5"], "IPv6 halves make a catch-all")
        check(NetstatRoutes.internetCarriers(v6, family: .ipv4).isEmpty, "families are not mixed")

        // Ordering: errors first.
        check(taken.map(\.severity) == taken.map(\.severity).sorted(by: >), "findings are sorted by severity")
        print("PASS: network conflict analysis")
    }
}
