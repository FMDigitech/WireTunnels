import Foundation

@main
struct IPFamilyRoutingTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    static func config(address: String, allowedIPs: String) -> ParsedConfig {
        WireGuardConfigParser().parse(string: """
        [Interface]
        PrivateKey = \(Data(repeating: 1, count: 32).base64EncodedString())
        Address = \(address)
        DNS = 1.1.1.1
        [Peer]
        PublicKey = \(Data(repeating: 2, count: 32).base64EncodedString())
        \(allowedIPs)
        Endpoint = 192.0.2.1:51820
        """)
    }

    static func main() {
        check(IPFamilyRouting.family(of: "10.0.0.2/32") == .ipv4, "an IPv4 CIDR is IPv4")
        check(IPFamilyRouting.family(of: " fd00::1/128 ") == .ipv6, "an IPv6 CIDR with spaces is IPv6")
        check(IPFamilyRouting.family(of: "vpn.example") == nil, "a host name has no family")

        check(IPFamilyRouting.routesAll(.ipv4, allowedIPs: ["0.0.0.0/0"]), "0.0.0.0/0 routes all IPv4")
        check(IPFamilyRouting.routesAll(.ipv4, allowedIPs: ["0.0.0.0/1", "128.0.0.0/1"]), "both IPv4 halves route all IPv4")
        check(!IPFamilyRouting.routesAll(.ipv4, allowedIPs: ["0.0.0.0/1"]), "one IPv4 half is not all")
        check(!IPFamilyRouting.routesAll(.ipv4, allowedIPs: ["10.0.0.0/8"]), "a private range is not all")
        check(IPFamilyRouting.routesAll(.ipv6, allowedIPs: ["::/0"]), "::/0 routes all IPv6")
        check(IPFamilyRouting.routesAll(.ipv6, allowedIPs: ["0::/0"]), "a non-canonical ::/0 routes all IPv6")
        check(IPFamilyRouting.routesAll(.ipv6, allowedIPs: ["::/1", "8000::/1"]), "both IPv6 halves route all IPv6")
        check(!IPFamilyRouting.routesAll(.ipv6, allowedIPs: ["8000::/1"]), "one IPv6 half is not all")
        check(!IPFamilyRouting.routesAll(.ipv6, allowedIPs: ["0.0.0.0/0"]), "IPv4 default does not route IPv6")
        check(IPFamilyRouting.routedAllFamilies(allowedIPs: ["0.0.0.0/0", "::/0"]) == [.ipv4, .ipv6], "dual stack routes both")

        check(!IPFamilyRouting.hasAddress(.ipv6, in: ["10.10.0.2/32"]), "an IPv4 address is not IPv6")
        check(IPFamilyRouting.hasAddress(.ipv6, in: ["10.10.0.2/32", "fd00::2/128"]), "a ULA address is IPv6")

        check(IPFamilyRouting.internetFamilies(ofPhysicalAddresses: ["192.168.1.5", "fe80::1%en0", "fd12::5"]) == [.ipv4],
              "link-local and ULA IPv6 do not mean the network has IPv6")
        check(IPFamilyRouting.internetFamilies(ofPhysicalAddresses: ["192.168.1.5", "fe80::1%en0", "2a00:1028::5"]) == [.ipv4, .ipv6],
              "a global IPv6 address means the network has IPv6")
        check(IPFamilyRouting.internetFamilies(ofPhysicalAddresses: ["169.254.3.3"]).isEmpty,
              "an IPv4 link-local address does not mean the network has IPv4")

        let v4Only = config(address: "10.10.0.2/32", allowedIPs: "AllowedIPs = 0.0.0.0/0, ::/0")
        check(v4Only.isValid && v4Only.warnings.contains(.ipv6RoutedWithoutAddress), "::/0 without an IPv6 address warns")
        check(!v4Only.warnings.contains(.ipv4RoutedWithoutAddress), "0.0.0.0/0 with an IPv4 address does not warn")
        let dual = config(address: "10.10.0.2/32, fd00::2/128", allowedIPs: "AllowedIPs = 0.0.0.0/0, ::/0")
        check(!dual.warnings.contains(.ipv6RoutedWithoutAddress), "::/0 with an IPv6 address does not warn")
        let lower = config(address: "10.10.0.2/32", allowedIPs: "allowedips = ::/0")
        check(lower.warnings.contains(.ipv6RoutedWithoutAddress), "lowercase keys are checked too")
        let v6Only = config(address: "fd00::2/128", allowedIPs: "AllowedIPs = ::/0")
        check(!v6Only.warnings.contains(.ipv4RoutedWithoutAddress) && !v6Only.warnings.contains(.ipv6RoutedWithoutAddress),
              "a tunnel that does not route IPv4 has no IPv4 editor warning")
        let v4NoAddress = config(address: "fd00::2/128", allowedIPs: "AllowedIPs = 0.0.0.0/0")
        check(v4NoAddress.warnings.contains(.ipv4RoutedWithoutAddress), "0.0.0.0/0 without an IPv4 address warns")

        check(IPFamilyRouting.hasAddress(.ipv6, in: ["fd00::2/128 # dual"]), "an inline comment does not hide an address")
        check(IPFamilyRouting.routesAll(.ipv6, allowedIPs: ["::/0 # everything"]), "an inline comment does not hide a route")
        let commented = config(address: "10.10.0.2/32, fd00::2/128 # dual stack", allowedIPs: "AllowedIPs = 0.0.0.0/0, ::/0")
        check(!commented.warnings.contains(.ipv6RoutedWithoutAddress), "an inline comment after the address does not warn")
        let repeated = WireGuardConfigParser().parse(string: """
        [Interface]
        PrivateKey = \(Data(repeating: 1, count: 32).base64EncodedString())
        Address = 10.0.0.2/32
        Address = fd00::2/128
        DNS = 1.1.1.1
        DNS = 2606:4700:4700::1111
        [Peer]
        PublicKey = \(Data(repeating: 2, count: 32).base64EncodedString())
        AllowedIPs = 0.0.0.0/0
        AllowedIPs = ::/0
        """)
        check(repeated.address == ["10.0.0.2/32", "fd00::2/128"] && repeated.allowedIPs == ["0.0.0.0/0", "::/0"]
              && repeated.dns == ["1.1.1.1", "2606:4700:4700::1111"], "repeated keys add up like wg-quick: \(repeated.address)")
        check(repeated.warnings.allSatisfy { $0 != .ipv4RoutedWithoutAddress && $0 != .ipv6RoutedWithoutAddress },
              "repeated Address lines do not warn")

        print("PASS: route-all families are detected and editor warnings flag a missing address family")
    }
}
