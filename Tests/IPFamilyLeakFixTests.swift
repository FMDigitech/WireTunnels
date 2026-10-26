import Foundation

@main
struct IPFamilyLeakFixTests {
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    static func main() {
        let v6Comment = "# Placeholder address added by WireTunnels to keep IPv6 from leaking. Remove it once the tunnel has a real IPv6 address."
        check(IPFamilyLeakFix.markerComment(for: .ipv6) == v6Comment, "IPv6 marker comment copy")

        let home = """
        [Interface]
        PrivateKey = KEY
        # my note
        Address = 10.10.0.2/32
        DNS = 192.168.88.1
        MTU = 1380

        [Peer]
        PublicKey = PEER
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = vpn.example:13231

        """
        let fixedHome = IPFamilyLeakFix.apply(to: home, family: .ipv6, placeholder: "fd12:3456:789a::1/128")
        check(fixedHome == """
        [Interface]
        PrivateKey = KEY
        # my note
        \(v6Comment)
        Address = 10.10.0.2/32, fd12:3456:789a::1/128
        DNS = 192.168.88.1
        MTU = 1380

        [Peer]
        PublicKey = PEER
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = vpn.example:13231

        """, "a missing IPv6 address gets a commented placeholder and nothing else changes:\n\(fixedHome)")
        check(IPFamilyLeakFix.apply(to: fixedHome, family: .ipv6, placeholder: "fd99::1/128") == fixedHome,
              "running the fix twice changes nothing")

        let v4Full = "[Interface]\nAddress = 10.10.0.2/32\n[Peer]\nAllowedIPs = 0.0.0.0/0\n"
        check(IPFamilyLeakFix.apply(to: v4Full, family: .ipv6, placeholder: "fd12::1/128")
              == "[Interface]\n\(v6Comment)\nAddress = 10.10.0.2/32, fd12::1/128\n[Peer]\nAllowedIPs = 0.0.0.0/0, ::/0\n",
              "an IPv4-only full tunnel also gets ::/0")

        let v4Comment = IPFamilyLeakFix.markerComment(for: .ipv4)
        check(v4Comment.contains("keep IPv4 from leaking") && v4Comment.contains("real IPv4 address"), "IPv4 marker comment copy")
        let v6Full = "[Interface]\nAddress = fd00::2/128\n[Peer]\nAllowedIPs = ::/0\n"
        check(IPFamilyLeakFix.apply(to: v6Full, family: .ipv4, placeholder: "198.18.7.9/32")
              == "[Interface]\n\(v4Comment)\nAddress = fd00::2/128, 198.18.7.9/32\n[Peer]\nAllowedIPs = ::/0, 0.0.0.0/0\n",
              "an IPv6-only full tunnel gets an IPv4 placeholder and 0.0.0.0/0")

        let lower = "[interface]\naddress = 10.10.0.2/32\n[peer]\nallowedips = 0.0.0.0/0\n"
        check(IPFamilyLeakFix.apply(to: lower, family: .ipv6, placeholder: "fd12::1/128")
              == "[interface]\n\(v6Comment)\naddress = 10.10.0.2/32, fd12::1/128\n[peer]\nallowedips = 0.0.0.0/0, ::/0\n",
              "lowercase sections and keys are edited")

        let noAddress = "[Interface]\nPrivateKey = KEY\n[Peer]\nAllowedIPs = 0.0.0.0/0, ::/0\n"
        check(IPFamilyLeakFix.apply(to: noAddress, family: .ipv6, placeholder: "fd12::1/128")
              == "[Interface]\n\(v6Comment)\nAddress = fd12::1/128\nPrivateKey = KEY\n[Peer]\nAllowedIPs = 0.0.0.0/0, ::/0\n",
              "a config without an Address line gets one after [Interface]")

        let twoPeers = "[Interface]\nAddress = 10.0.0.2/32\n[Peer]\nAllowedIPs = 0.0.0.0/0\n[Peer]\nAllowedIPs = 10.9.0.0/16\n"
        check(IPFamilyLeakFix.apply(to: twoPeers, family: .ipv6, placeholder: "fd12::1/128")
              == "[Interface]\n\(v6Comment)\nAddress = 10.0.0.2/32, fd12::1/128\n[Peer]\nAllowedIPs = 0.0.0.0/0, ::/0\n[Peer]\nAllowedIPs = 10.9.0.0/16\n",
              "only the first peer's AllowedIPs change")

        let crlf = "[Interface]\r\nAddress = 10.0.0.2/32\r\n[Peer]\r\nAllowedIPs = 0.0.0.0/0, ::/0\r\n"
        check(IPFamilyLeakFix.apply(to: crlf, family: .ipv6, placeholder: "fd12::1/128")
              == "[Interface]\r\n\(v6Comment)\r\nAddress = 10.0.0.2/32, fd12::1/128\r\n[Peer]\r\nAllowedIPs = 0.0.0.0/0, ::/0\r\n",
              "CRLF line endings are kept")

        var generator = SeededGenerator(state: 42)
        for _ in 0..<50 {
            let v6 = IPFamilyLeakFix.placeholderAddress(for: .ipv6, using: &generator)
            check(v6.range(of: "^fd[0-9a-f]{2}:[0-9a-f]{1,4}:[0-9a-f]{1,4}::1/128$", options: .regularExpression) != nil
                  && IPFamilyRouting.family(of: v6) == .ipv6, "IPv6 placeholder shape: \(v6)")
            let v4 = IPFamilyLeakFix.placeholderAddress(for: .ipv4, using: &generator)
            let octets = v4.dropLast(3).split(separator: ".").compactMap { Int($0) }
            check((v4.hasPrefix("198.18.") || v4.hasPrefix("198.19.")) && v4.hasSuffix("/32")
                  && octets.count == 4 && (1...254).contains(octets[3]), "IPv4 placeholder shape: \(v4)")
        }

        let missing = IPFamilyLeak(family: .ipv6, reason: .missingAddress)
        func reason(_ leak: IPFamilyLeak = missing, dns: [String] = ["1.1.1.1"], managed: Bool = false,
                    inventory: Bool = false, busy: Bool = false) -> IPFamilyLeakFix.UnavailableReason? {
            IPFamilyLeakFix.unavailableReason(for: leak, dns: dns, isManaged: managed, hasInventory: inventory, isBusy: busy)
        }
        check(reason() == nil, "a plain personal tunnel can be fixed")
        check(reason(IPFamilyLeak(family: .ipv6, reason: .routeBypassed)) == .routeBypassed, "bypassed routes cannot be fixed")
        check(reason(managed: true) == .managed, "managed tunnels cannot be fixed")
        check(reason(inventory: true) == .inventoryProtected, "inventory tunnels cannot be fixed")
        check(reason(busy: true) == .busy, "busy tunnels cannot be fixed")
        check(reason(dns: ["2606:4700:4700::1111"]) == .dnsUsesFamily, "IPv6-only DNS blocks disabling IPv6")
        check(reason(dns: ["2606:4700:4700::1111", "1.1.1.1"]) == nil, "mixed DNS keeps the fix")
        check(reason(dns: []) == nil, "no DNS keeps the fix")
        check(reason(dns: ["home.lan"]) == nil, "a search domain is not a DNS server")
        check(IPFamilyLeakFix.dnsUnavailableMessage(for: .ipv6)
              == "The fix is not available because this tunnel's DNS servers use IPv6.", "DNS message copy")

        print("PASS: the leak fix adds a commented placeholder address and default route only where missing")
    }
}
