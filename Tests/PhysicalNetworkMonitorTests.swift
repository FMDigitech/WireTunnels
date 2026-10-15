import Foundation

@main
struct PhysicalNetworkMonitorTests {
    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
    }

    @MainActor
    static func main() async throws {
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("physical-network-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        func wifi(_ address: String = "192.0.2.10") -> PhysicalNetworkSnapshot {
            PhysicalNetworkSnapshot(interfaces: [.init(name: "en0", kind: .wifi, isLinkActive: true,
                addresses: [address, "fe80::1%en0"])], preferredPrimaryInterface: "en0")
        }
        var physical: PhysicalNetworkSnapshot? = wifi()
        let service = NetworkMonitorService(readPhysicalNetwork: { physical }, diagnostics: LogService(logFile: logURL))
        var changes = 0
        var renewals = 0
        service.onNetworkChange = { changes += 1 }
        service.onLocalAddressChange = { renewals += 1 }
        var tunnel = Tunnel(name: "Synthetic tunnel", configPath: "/private/tmp/synthetic.conf")
        tunnel.autoConnectRule.connect = .init(enabled: true, interface: .wifi)
        await service.refreshNetworkState()
        expect(service.matchesConnect(tunnel), "physical Wi-Fi must match before tunnel startup")
        let beforeRouteChanges = changes

        // Recorded macOS behavior: default and prohibited-interface NWPath monitors
        // both flip to wifi=false during wg-quick up, while the physical link/IP
        // state below remains unchanged. Refresh the real service for those events.
        for _ in 0..<10 {
            await service.refreshNetworkState()
            expect(service.matchesConnect(tunnel), "VPN route changes must not break a physical Wi-Fi rule")
        }
        expect(changes == beforeRouteChanges && renewals == 0,
            "unchanged physical state must not trigger disconnects or renewal reconnects")
        physical = nil
        await service.refreshNetworkState()
        expect(service.matchesConnect(tunnel) && changes == beforeRouteChanges,
            "an unavailable system snapshot must not be mistaken for a physical disconnect")

        physical = wifi("192.0.2.20")
        await service.refreshNetworkState()
        expect(renewals == 1 && changes == beforeRouteChanges + 1,
            "an actual DHCP renewal must still trigger exactly one reconnect and rule evaluation")
        func both(_ ethernetAddress: String, ipv6: String = "2001:db8::20", primary: String) -> PhysicalNetworkSnapshot {
            PhysicalNetworkSnapshot(interfaces: [
                .init(name: "en0", kind: .wifi, isLinkActive: true, addresses: ["192.0.2.20"]),
                .init(name: "en7", kind: .ethernet, isLinkActive: true, addresses: [ethernetAddress, ipv6])
            ], preferredPrimaryInterface: primary)
        }
        physical = both("198.51.100.10", primary: "en7")
        await service.refreshNetworkState()
        physical = both("198.51.100.10", primary: "utun42")
        await service.refreshNetworkState()
        expect(renewals == 1, "a VPN becoming the global primary must not look like DHCP renewal")
        physical = both("198.51.100.20", primary: "utun42")
        await service.refreshNetworkState()
        expect(renewals == 2,
            "Ethernet DHCP renewal must be detected while Wi-Fi and a VPN global primary are also present")
        physical = both("198.51.100.20", ipv6: "2001:db8::21", primary: "utun42")
        await service.refreshNetworkState()
        expect(renewals == 2, "an IPv6-only change must reevaluate subnets without an IPv4 restart")
        physical = PhysicalNetworkSnapshot(interfaces: [
            .init(name: "en0", kind: .wifi, isLinkActive: false, addresses: ["192.0.2.20"]),
            .init(name: "en7", kind: .ethernet, isLinkActive: true, addresses: ["198.51.100.20", "2001:db8::20"])
        ], preferredPrimaryInterface: "en7")
        await service.refreshNetworkState()
        expect(!service.matchesConnect(tunnel), "an actual Wi-Fi link loss must stop matching even with stale addresses")
        tunnel.autoConnectRule.connect = .init(enabled: true, interface: .ethernet)
        expect(service.matchesConnect(tunnel), "the active Ethernet interface must match its rule")
        expect(service.ethernetAddresses == ["198.51.100.20", "2001:db8::20"],
            "only active Ethernet addresses may be published")
        expect(renewals == 2, "a real interface switch must not count as DHCP renewal")
        physical = PhysicalNetworkSnapshot(interfaces: [
            .init(name: "en7", kind: .ethernet, isLinkActive: false, addresses: ["198.51.100.20"])
        ], preferredPrimaryInterface: "en7")
        await service.refreshNetworkState()
        expect(!service.matchesConnect(tunnel) && service.ethernetAddresses.isEmpty,
            "an unplugged Ethernet interface with stale IPs must not match")
        physical = PhysicalNetworkSnapshot(interfaces: [
            .init(name: "en7", kind: .ethernet, isLinkActive: true, addresses: [])
        ], preferredPrimaryInterface: "en7")
        await service.refreshNetworkState()
        expect(!service.isOnEthernet, "a link without configured addresses must not match")
        physical = wifi()
        await service.refreshNetworkState()
        tunnel.autoConnectRule.connect.interface = .wifi
        expect(service.matchesConnect(tunnel), "physical Wi-Fi reconnection must restore matching")
        print("PASS: physical link rules ignore VPN routes and handle DHCP, real link loss, switches, and unavailable snapshots")
    }
}
