import Foundation

@main
struct RouteLookupTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    static func output(interface: String) -> String {
        """
           route to: 2606:4700:4700::1111
        destination: ::
               mask: 8000::
          interface: \(interface)
              flags: <UP,DONE,STATIC,PRCLONING,GLOBAL>
         recvpipe  sendpipe  ssthresh  rtt,msec    rttvar  hopcount      mtu     expire
               0         0         0         0         0         0      1420         0
        """
    }

    static func main() {
        check(RouteLookupService.parseInterface(fromRouteGetOutput: output(interface: "en0")) == "en0", "parses en0")
        check(RouteLookupService.parseInterface(fromRouteGetOutput: output(interface: "utun6")) == "utun6", "parses utun6")
        check(RouteLookupService.parseInterface(fromRouteGetOutput: "route: writing to routing socket: not in table") == nil,
              "a failed lookup has no interface")
        check(RouteLookupService.parseInterface(fromRouteGetOutput: "") == nil, "empty output has no interface")

        let tunnel: Set<String> = ["utun6"]
        check(RouteLookupService.bypassedFamilies([.ipv6], tunnelInterfaces: tunnel, lookup: { _, _ in "en0" }) == [.ipv6],
              "a probe resolving to Wi-Fi bypasses the tunnel")
        check(RouteLookupService.bypassedFamilies([.ipv6], tunnelInterfaces: tunnel, lookup: { _, _ in "utun6" }).isEmpty,
              "a probe resolving to the tunnel is fine")
        let ipv4Probes = RouteLookupService.probeDestinations[.ipv4] ?? []
        check(ipv4Probes.count == 2, "IPv4 probes cover both /1 halves")
        let split = RouteLookupService.bypassedFamilies([.ipv4], tunnelInterfaces: ["utun4", "utun6"],
                                                        lookup: { destination, _ in destination == ipv4Probes[0] ? "utun4" : "utun6" })
        check(split.isEmpty, "probes landing on any connected tunnel are fine")
        check(RouteLookupService.bypassedFamilies([.ipv4, .ipv6], tunnelInterfaces: tunnel, lookup: { _, _ in nil }).isEmpty,
              "failed lookups never report a leak")
        check(RouteLookupService.bypassedFamilies([.ipv6], tunnelInterfaces: tunnel, lookup: { _, _ in "lo0" }).isEmpty,
              "a blackhole route on lo0 is not a leak")
        check(RouteLookupService.bypassedFamilies([.ipv4], tunnelInterfaces: tunnel,
                                                  lookup: { _, family in family == .ipv6 ? "en0" : "utun6" }).isEmpty,
              "families that were not requested are not probed")

        print("PASS: route lookups parse the interface and report families sent around every tunnel")
    }
}
