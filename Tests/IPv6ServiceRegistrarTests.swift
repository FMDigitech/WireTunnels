import Darwin
import Foundation

@main
struct IPv6ServiceRegistrarTests {
    static func bytes(_ text: String) -> [UInt8] {
        var address = in6_addr()
        precondition(inet_pton(AF_INET6, text, &address) == 1)
        return withUnsafeBytes(of: address) { Array($0) }
    }

    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    static func main() {
        let full = "[Interface]\nAddress = 10.0.0.2/32, fd00::2/64\n[Peer]\nAllowedIPs = 0.0.0.0/0, ::/0 # all\n"
        check(IPv6ServiceRegistrar.routesAllIPv6(config: full), "::/0 must count as a full IPv6 tunnel")
        check(IPv6ServiceRegistrar.routesAllIPv6(config: "[Peer]\nAllowedIPs = 10.0.0.0/8\nallowedips=::/0\n"),
              "repeated, lowercase AllowedIPs lines add up like wg-quick")
        check(!IPv6ServiceRegistrar.routesAllIPv6(config: "[Peer]\nAllowedIPs = 0.0.0.0/0, 2001:db8::/32\n"),
              "a split IPv6 tunnel must not be published")
        check(!IPv6ServiceRegistrar.routesAllIPv6(config: "[Interface]\nTable = off\n[Peer]\nAllowedIPs = ::/0\n"),
              "Table = off installs no routes")
        check(!IPv6ServiceRegistrar.routesAllIPv6(config: "[Peer]\n# AllowedIPs = ::/0\nAllowedIPs = 0.0.0.0/0\n"),
              "a commented-out ::/0 must be ignored")
        check(!IPv6ServiceRegistrar.routesAllIPv6(config: "[Interface]\nAllowedIPs = ::/0\n"),
              "AllowedIPs outside [Peer] is not a route")

        check(IPv6ServiceRegistrar.serviceValue(interface: "utun4", addresses: []) == nil,
              "a tunnel without a global IPv6 address must not be published")
        let value = IPv6ServiceRegistrar.serviceValue(interface: "utun4",
            addresses: [(bytes("2001:db8:1:2::5"), 60), (bytes("fd00::2"), 128)])!
        check(value["Addresses"] as? [String] == ["2001:db8:1:2::5", "fd00::2"], "addresses keep their order")
        check(value["PrefixLength"] as? [Int] == [60, 128], "prefix lengths match the addresses")
        check(value["InterfaceName"] as? String == "utun4", "the service names its utun")
        check(value["Router"] as? String == "2001:db8:1::", "router is the first address's /60 network")
        let host = IPv6ServiceRegistrar.serviceValue(interface: "utun4", addresses: [(bytes("fd00::2"), 128)])!
        check(host["Router"] as? String == "fd00::2", "a /128 address is its own network")

        let a = IPv6ServiceRegistrar.key(for: "utun4"), b = IPv6ServiceRegistrar.key(for: "utun7")
        check(a.range(of: IPv6ServiceRegistrar.keyPattern, options: .regularExpression) != nil
              && "State:/Network/Service/A1B2/IPv6".range(of: IPv6ServiceRegistrar.keyPattern, options: .regularExpression) == nil,
              "the key pattern matches only WireTunnels services")
        let v1: NSDictionary = ["InterfaceName": "utun4"], v2: NSDictionary = ["InterfaceName": "utun4", "Router": "fd00::"]
        let same = IPv6ServiceRegistrar.plan(desired: [a: v1], present: [a: v1])
        check(same.remove.isEmpty && same.add.isEmpty, "an unchanged service is left alone")
        let changed = IPv6ServiceRegistrar.plan(desired: [a: v2], present: [a: v1, b: v1])
        check(changed.remove == [a, b] && changed.add == [a],
              "a changed service is replaced and a gone tunnel's service removed")
        let fresh = IPv6ServiceRegistrar.plan(desired: [a: v1], present: [:])
        check(fresh.remove.isEmpty && fresh.add == [a], "a new tunnel is published")
        print("PASS: IPv6 service registration publishes only full IPv6 tunnels and reconciles stale keys")
    }
}
