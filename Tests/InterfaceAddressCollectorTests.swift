import Foundation
import Darwin

@main
struct InterfaceAddressCollectorTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func main() {
        let active = UInt32(IFF_UP | IFF_RUNNING)
        let entries: [InterfaceAddressCollector.Entry] = [
            .init(interfaceName: "en7", family: AF_INET6, flags: active, address: "2001:db8::7"),
            .init(interfaceName: "en7", family: AF_INET, flags: active, address: "192.0.2.7"),
            .init(interfaceName: "en7", family: AF_INET, flags: active, address: "192.0.2.7"),
            .init(interfaceName: "en7", family: AF_INET6, flags: active, address: "fe80::7%en7"),
            .init(interfaceName: "en0", family: AF_INET, flags: active, address: "198.51.100.2"),
            .init(interfaceName: "utun4", family: AF_INET, flags: active, address: "203.0.113.4"),
            .init(interfaceName: "en8", family: AF_INET, flags: UInt32(IFF_UP), address: "192.0.2.8"),
            .init(interfaceName: "en9", family: AF_INET, flags: UInt32(IFF_RUNNING), address: "192.0.2.9"),
            .init(interfaceName: "en10", family: AF_INET, flags: active | UInt32(IFF_LOOPBACK), address: "127.0.0.1"),
            .init(interfaceName: "en7", family: AF_LINK, flags: active, address: "00:00:00:00:00:07"),
            .init(interfaceName: "en7", family: AF_INET, flags: active, address: nil),
            .init(interfaceName: "en7", family: AF_INET6, flags: active, address: "")
        ]

        expect(InterfaceAddressCollector.addresses(on: ["en7", "en8", "en9", "en10"], entries: entries)
            == ["192.0.2.7", "2001:db8::7", "fe80::7%en7"],
            "only active non-loopback Ethernet IPs are collected, deduplicated and sorted")
        expect(InterfaceAddressCollector.addresses(on: [], entries: entries).isEmpty,
            "Wi-Fi or VPN addresses cannot match when the path has no Ethernet interface")
        expect(InterfaceAddressCollector.addresses(on: ["en20"], entries: entries).isEmpty,
            "missing Ethernet addresses fail closed")
        expect(InterfaceAddressCollector.addresses(on: ["en7"], entries: entries.reversed())
            == ["192.0.2.7", "2001:db8::7", "fe80::7%en7"],
            "interface enumeration order does not change the address snapshot")

        let previous = InterfaceAddressSnapshot(ethernetAddresses: ["192.0.2.7"],
            primaryInterfaceName: "en7", primaryIPv4Address: "192.0.2.7")
        expect(!previous.requiresRuleEvaluation(after: previous),
            "unchanged physical addresses ignore unrelated VPN and DNS notifications")
        let renewed = InterfaceAddressSnapshot(ethernetAddresses: ["192.0.2.8"],
            primaryInterfaceName: "en7", primaryIPv4Address: "192.0.2.8")
        expect(renewed.requiresRuleEvaluation(after: previous) && renewed.primaryIPv4Changed(after: previous),
            "DHCP changes reevaluate rules and reconnect the same primary interface")
        let ipv6Changed = InterfaceAddressSnapshot(ethernetAddresses: ["192.0.2.7", "2001:db8::8"],
            primaryInterfaceName: "en7", primaryIPv4Address: "192.0.2.7")
        expect(ipv6Changed.requiresRuleEvaluation(after: previous) && !ipv6Changed.primaryIPv4Changed(after: previous),
            "IPv6 changes reevaluate subnet rules without triggering IPv4 reconnect")
        let unknown = InterfaceAddressSnapshot(ethernetAddresses: [],
            primaryInterfaceName: "en7", primaryIPv4Address: nil)
        expect(unknown.requiresRuleEvaluation(after: previous) && !unknown.primaryIPv4Changed(after: previous),
            "losing known Ethernet addresses reevaluates rules to fail closed")
        expect(!renewed.primaryIPv4Changed(after: nil),
            "the first address snapshot is not a DHCP renewal")
        let switched = InterfaceAddressSnapshot(ethernetAddresses: [],
            primaryInterfaceName: "en0", primaryIPv4Address: "198.51.100.2")
        expect(!switched.primaryIPv4Changed(after: previous),
            "switching physical interfaces does not masquerade as a DHCP renewal")
        let wifiPrevious = InterfaceAddressSnapshot(ethernetAddresses: [],
            primaryInterfaceName: "en0", primaryIPv4Address: "198.51.100.2")
        let wifiRenewed = InterfaceAddressSnapshot(ethernetAddresses: [],
            primaryInterfaceName: "en0", primaryIPv4Address: "198.51.100.3")
        expect(wifiRenewed.requiresRuleEvaluation(after: wifiPrevious) && wifiRenewed.primaryIPv4Changed(after: wifiPrevious),
            "Wi-Fi DHCP fingerprint behavior is preserved")
        print("PASS: Ethernet interface address collection")
    }
}
