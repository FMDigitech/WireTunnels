import Foundation

@main
struct IPFamilyLeakDetectorTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    static func input(_ allowed: [String], _ address: [String], acknowledged: Bool = false) -> IPFamilyLeakInput {
        IPFamilyLeakInput(id: UUID(), routing: TunnelRouting(address: address, allowedIPs: allowed, dns: []),
                          acknowledged: acknowledged)
    }

    static func leaks(_ connected: [IPFamilyLeakInput], physical: Set<IPFamily> = [.ipv4, .ipv6],
                      bypassed: Set<IPFamily> = [], killSwitch: Bool = false) -> [UUID: [IPFamilyLeak]] {
        IPFamilyLeakDetector.leaks(connected: connected, physicalFamilies: physical,
                                   routeBypassedFamilies: bypassed, killSwitchArmed: killSwitch)
    }

    static func main() {
        let all = ["0.0.0.0/0", "::/0"]
        let home = input(all, ["10.10.0.2/32"])
        check(leaks([home]) == [home.id: [IPFamilyLeak(family: .ipv6, reason: .missingAddress)]],
              "::/0 without an IPv6 address leaks IPv6")
        check(leaks([input(all, ["10.10.0.2/32", "fd00::2/128"])]).isEmpty, "a dual-stack tunnel with both addresses is fine")

        let v4Full = input(["0.0.0.0/0"], ["10.10.0.2/32"])
        check(leaks([v4Full], physical: [.ipv4]).isEmpty, "an IPv4-only full tunnel on an IPv4-only network is fine")
        check(leaks([v4Full]) == [v4Full.id: [IPFamilyLeak(family: .ipv6, reason: .notRouted)]],
              "an IPv4-only full tunnel on an IPv6 network leaks IPv6")
        let v6Full = input(["::/0"], ["fd00::2/128"])
        check(leaks([v6Full]) == [v6Full.id: [IPFamilyLeak(family: .ipv4, reason: .notRouted)]],
              "an IPv6-only full tunnel on an IPv4 network leaks IPv4")

        let v6Real = input(["::/0"], ["2001:db8::2/128"])
        check(leaks([v4Full, v6Real]).isEmpty, "complementary tunnels cover each other")
        let hop = input(all, ["10.0.0.2/32", "fd00::2/128"]), exit = input(all, ["10.1.0.2/32", "fd01::2/128"])
        check(leaks([hop, exit]).isEmpty, "two dual-stack tunnels (a multi-hop chain) do not leak")
        let otherV4 = input(["0.0.0.0/0"], ["10.20.0.2/32"])
        let both = leaks([v4Full, otherV4])
        check(both[v4Full.id] == [IPFamilyLeak(family: .ipv6, reason: .notRouted)]
              && both[otherV4.id] == [IPFamilyLeak(family: .ipv6, reason: .notRouted)],
              "two IPv4-only full tunnels both leak IPv6")

        let acknowledgedLeak = input(all, ["10.10.0.2/32"], acknowledged: true)
        let acknowledgedLeaks = leaks([acknowledgedLeak])
        check(acknowledgedLeaks == [acknowledgedLeak.id: [IPFamilyLeak(family: .ipv6, reason: .missingAddress)]],
              "an acknowledged tunnel still reports its leak for the route label")
        check(IPFamilyLeakDetector.warnings(from: acknowledgedLeaks, connected: [acknowledgedLeak]).isEmpty,
              "an acknowledged tunnel gets no warning")
        check(IPFamilyLeakDetector.warnings(from: leaks([home]), connected: [home]) == leaks([home]),
              "an unacknowledged tunnel keeps its warning")
        check(IPFamilyLeakDetector.routeLabel(allowedIPs: all, leaks: acknowledgedLeaks[acknowledgedLeak.id] ?? [])
              == "All IPv4 traffic", "the label stays honest when the warning is acknowledged")
        check(IPFamilyLeakDetector.routeLabel(allowedIPs: all, leaks: []) == "All traffic (IPv4+IPv6)", "dual stack label")
        check(IPFamilyLeakDetector.routeLabel(allowedIPs: ["0.0.0.0/0"], leaks: []) == "All IPv4 traffic",
              "an IPv4-only full tunnel never claims all traffic")
        check(IPFamilyLeakDetector.routeLabel(allowedIPs: ["::/0"], leaks: []) == "All IPv6 traffic", "IPv6-only label")
        check(IPFamilyLeakDetector.routeLabel(allowedIPs: ["10.0.0.0/8"], leaks: []) == nil, "split tunnels keep their own label")
        let acknowledgedDual = input(all, ["10.0.0.2/32", "fd00::2/128"], acknowledged: true)
        check(leaks([acknowledgedDual, v4Full]).isEmpty, "an acknowledged tunnel still covers its families for others")

        let dual = input(all, ["10.10.0.2/32", "fd00::2/128"])
        let bypassed = leaks([dual], bypassed: [.ipv6])
        check(bypassed == [dual.id: [IPFamilyLeak(family: .ipv6, reason: .routeBypassed)]],
              "a family the routing table sends around the tunnel leaks")
        check(bypassed[dual.id]?.first?.fixDescription == nil, "a bypassed route has no placeholder fix")

        check(leaks([home], killSwitch: true).isEmpty, "an armed kill switch blocks every leak")
        check(leaks([input(["10.0.0.0/8"], ["10.10.0.2/32"])]).isEmpty, "a split tunnel never warns")

        let bothBroken = input(["::/0"], ["10.10.0.2/32"])
        check(leaks([bothBroken])[bothBroken.id] == [IPFamilyLeak(family: .ipv4, reason: .notRouted),
                                                      IPFamilyLeak(family: .ipv6, reason: .missingAddress)],
              "leaks are sorted IPv4 first")

        let missing = IPFamilyLeak(family: .ipv6, reason: .missingAddress)
        check(missing.title == "IPv6 is leaking", "title copy")
        check(missing.problem == "This tunnel has no IPv6 address, so IPv6 traffic goes around it.", "missing address copy")
        check(missing.fixDescription == "The fix disables IPv6 for this tunnel by adding a placeholder IPv6 address.",
              "missing address fix copy")
        let notRouted = IPFamilyLeak(family: .ipv4, reason: .notRouted)
        check(notRouted.problem == "This tunnel does not route IPv4, and this network has IPv4, so IPv4 traffic goes around it.",
              "not routed copy")
        check(notRouted.fixDescription == "The fix disables IPv4 for this tunnel by routing it into the tunnel with a placeholder address.",
              "not routed fix copy")
        check(IPFamilyLeak(family: .ipv6, reason: .routeBypassed).problem
              == "The tunnel is set to route all IPv6 traffic, but macOS sends it around the tunnel.", "bypassed copy")

        print("PASS: leak detection covers missing addresses, unrouted families, bypassed routes and shared coverage")
    }
}
