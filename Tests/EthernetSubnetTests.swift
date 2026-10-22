import Foundation

@main
struct EthernetSubnetTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func main() throws {
        let json = #"{"connect":{"enabled":true,"interface":"ethernet","ethernetSubnets":["192.0.2.0/24"]},"disconnect":{"enabled":true,"interface":"both","wifiSSIDs":["Office"],"ethernetSubnets":["2001:db8::/32"]}}"#
        let rule = try JSONDecoder().decode(AutoConnectRule.self, from: Data(json.utf8))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as! [String: Any]
        let connect = encoded["connect"] as! [String: Any]
        expect(connect["ethernetSubnets"] as? [String] == ["192.0.2.0/24"], "saved Ethernet subnet filters must survive a JSON round trip")
        let disconnect = encoded["disconnect"] as! [String: Any]
        expect(disconnect["ethernetSubnets"] as? [String] == ["2001:db8::/32"], "disconnect subnet filters must survive a JSON round trip")
        expect(tryDecode(#"{"connect":{"enabled":true,"interface":"ethernet"}}"#).connect.matchesAnyEthernet, "old nested Ethernet rules must continue matching any Ethernet")
        let legacy = tryDecode(#"{"enabled":true,"interface":"both","action":"disconnect","wifiSSIDs":["Office"]}"#)
        expect(!legacy.connect.enabled && legacy.disconnect.enabled && legacy.disconnect.matchesAnyEthernet && legacy.disconnect.wifiSSIDs == ["Office"], "legacy disconnect migration must preserve Wi-Fi and default to any Ethernet")
        let legacySubnet = tryDecode(#"{"enabled":true,"interface":"ethernet","action":"connect","ethernetSubnets":["192.0.2.0/24"]}"#)
        expect(legacySubnet.connect.ethernetSubnets == ["192.0.2.0/24"], "legacy flat subnet filters must be retained")
        expect(tryDecode(#"{}"#) == AutoConnectRule(), "missing halves must retain disabled defaults")
        testSubnets()
        testMatching()
        print("PASS: Ethernet CIDR validation, persistence, and independent network matching")
    }

    static func tryDecode(_ json: String) -> AutoConnectRule {
        do {
            return try JSONDecoder().decode(AutoConnectRule.self, from: Data(json.utf8))
        } catch {
            fatalError("Synthetic rule JSON could not decode")
        }
    }

    static func testSubnets() {
        // Literal network boundaries catch host-bit leaks and incorrect partial-byte masks.
        let valid: [(String, String, [String], [String])] = [
            (" 192.0.2.99/24 \n", "192.0.2.0/24", ["192.0.2.0", "192.0.2.255"], ["192.0.1.255", "192.0.3.0", "2001:db8::1"]),
            ("198.51.100.253/25", "198.51.100.128/25", ["198.51.100.128", "198.51.100.255"], ["198.51.100.127", "198.51.101.0"]),
            ("203.0.113.7/0", "0.0.0.0/0", ["0.0.0.0", "255.255.255.255"], ["::1"]),
            ("192.0.2.9/32", "192.0.2.9/32", ["192.0.2.9"], ["192.0.2.8", "192.0.2.10"]),
            ("192.0.2.9/31", "192.0.2.8/31", ["192.0.2.8", "192.0.2.9"], ["192.0.2.7", "192.0.2.10"]),
            ("2001:0DB8:abcd:ffff::7/48", "2001:db8:abcd::/48", ["2001:db8:abcd::", "2001:db8:abcd:ffff:ffff:ffff:ffff:ffff"], ["2001:db8:abcc:ffff::1", "192.0.2.9"]),
            ("2001:db8:1:2:ffff::abcd/65", "2001:db8:1:2:8000::/65", ["2001:db8:1:2:8000::", "2001:db8:1:2:ffff:ffff:ffff:ffff"], ["2001:db8:1:2:7fff:ffff:ffff:ffff", "2001:db8:1:3::"]),
            ("2001:db8::1/0", "::/0", ["::", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"], ["192.0.2.1"]),
            ("2001:db8::1/128", "2001:db8::1/128", ["2001:db8::1", "2001:0db8:0000::1"], ["2001:db8::", "2001:db8::2"]),
            ("2001:db8::3/127", "2001:db8::2/127", ["2001:db8::2", "2001:db8::3"], ["2001:db8::1", "2001:db8::4"]),
            ("fe80::abcd/64", "fe80::/64", ["fe80::1%en0", "fe80::2%12"], ["fe80::1%", "fe80::1%en0%en1", "fe80::1%bad zone"])
        ]
        for (input, canonical, inside, outside) in valid {
            guard let subnet = IPSubnet(input) else {
                expect(false, "valid numeric CIDR must parse: \(input)")
                continue
            }
            expect(subnet.canonicalCIDR == canonical, "CIDR canonicalization must remove host bits: \(input)")
            for address in inside { expect(subnet.contains(address), "CIDR must contain boundary address \(address) in \(canonical)") }
            for address in outside { expect(!subnet.contains(address), "CIDR must reject outside address \(address) in \(canonical)") }
            for invalidAddress in ["example.test", "192.0.2.1/24", "2001:db8::1/64", "192.0.2.1%en0", "::1%bad/zone", "192.000.2.1", "::ffff:192.000.2.1", "192.0.2.1\0junk"] {
                expect(!subnet.contains(invalidAddress), "addresses must be numeric and scopes valid")
            }
        }
        for input in ["", "192.0.2.1", "::1", "192.0.2.1/", "192.0.2.1/-1", "192.0.2.1/33", "::/129", "::/-1", "192.0.2.1/+1", "192.0.2.1/24/2", "192.0.2.1/ 24", "192.0.2.1 /24", "192.0.2.1/2.0", "localhost/24", "300.0.0.1/24", "192.168.001.1/24", "fe80::1%en0/64", "2001:db8:::1/64", "[::1]/128", "::/１２", "192.0.2.1\0junk/24", "::/99999999999999999999999999", "::ffff:192.168.001.1/128", "127.1/16", "0x7f000001/32"] {
            expect(IPSubnet(input) == nil, "invalid CIDR must be rejected: \(input.debugDescription)")
        }
    }

    static func testMatching() {
        var rule = AutoConnectNetworkMatch(enabled: true, interface: .ethernet, ethernetSubnets: ["192.0.2.0/24"])
        func matches(_ ethernet: Bool = true, _ addresses: [String] = ["198.51.100.1"], _ wifi: Bool = false, _ ssid: String? = nil) -> Bool {
            AutoConnectNetworkMatcher.matches(rule, isOnEthernet: ethernet, ethernetAddresses: addresses, isOnWiFi: wifi, currentSSID: ssid)
        }
        expect(!matches(), "a nonmatching physical Ethernet address must not trigger a subnet rule")
        expect(matches(true, ["198.51.100.1", "192.0.2.40"]), "any matching physical address must satisfy an Ethernet subnet")
        expect(!matches(false, ["192.0.2.40"]), "matching addresses without Ethernet connectivity must not trigger")
        expect(!matches(true, []), "restricted Ethernet must not match when physical addresses are unavailable")
        rule.ethernetSubnets = ["2001:db8::/32", "192.0.2.0/24"]
        expect(matches(true, ["2001:db8:1::5"]), "Ethernet subnet entries must match with OR semantics")
        rule.ethernetSubnets = ["broken", "192.0.2.0/99"]
        expect(!rule.matchesAnyEthernet && !matches(), "invalid saved entries must never broaden a restricted rule to any Ethernet")
        rule.ethernetSubnets = ["", " "]
        expect(!rule.matchesAnyEthernet && !matches(), "blank saved entries must never be treated as any Ethernet")
        rule.ethernetSubnets = ["broken", "192.0.2.0/24"]
        expect(matches(true, ["192.0.2.3"]), "valid saved entries must still match alongside invalid entries")
        rule.ethernetSubnets = []
        expect(rule.matchesAnyEthernet && matches(true, []), "any Ethernet must match even when no address has been assigned")
        expect(!matches(false, [], true, "Office"), "Ethernet-only rules must ignore Wi-Fi")
        rule = AutoConnectNetworkMatch(enabled: true, interface: .both, wifiSSIDs: ["Office"], ethernetSubnets: ["192.0.2.0/24"])
        expect(matches(true, ["192.0.2.1"], false), "both must match Ethernet independently of Wi-Fi")
        expect(matches(false, [], true, "Office"), "both must match Wi-Fi independently of Ethernet")
        expect(matches(true, ["198.51.100.1"], true, "Office"), "a mismatching Ethernet subnet must not suppress matching Wi-Fi")
        expect(!matches(true, ["198.51.100.1"], true, "Guest"), "both must fail when neither network filter matches")
        expect(!matches(false, [], true, nil), "SSID-specific rules must fail when permission hides the Wi-Fi name")
        expect(matches(true, ["192.0.2.1"], true, nil), "hidden Wi-Fi names must not suppress matching Ethernet")
        rule.interface = .wifi
        expect(!matches(true, ["192.0.2.1"], false, "Office"), "Wi-Fi-only rules must ignore Ethernet")
        expect(!matches(false, [], false, "Office"), "a cached Wi-Fi name without connectivity must not match")
        rule.wifiSSIDs = []
        expect(matches(false, [], true, nil), "any Wi-Fi must work without name permission")
        rule.enabled = false
        expect(!matches(true, ["192.0.2.1"], true, "Office"), "disabled rules must never match")
    }
}
