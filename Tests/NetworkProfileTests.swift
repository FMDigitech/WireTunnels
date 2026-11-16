import Foundation

@main
struct NetworkProfileTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func main() throws {
        func profile(_ name: String, _ match: AutoConnectNetworkMatch) -> NetworkProfile {
            NetworkProfile(name: name, match: match)
        }
        func first(_ profiles: [NetworkProfile], wifi: String? = nil, ethernet: [String] = []) -> String? {
            NetworkProfileResolver.firstMatch(in: profiles, isOnEthernet: !ethernet.isEmpty, ethernetAddresses: ethernet,
                                              isOnWiFi: wifi != nil, currentSSID: wifi)?.name
        }
        let office = profile("Office", AutoConnectNetworkMatch(enabled: true, interface: .wifi, wifiSSIDs: ["Office"]))
        let anyWiFi = profile("Any Wi-Fi", AutoConnectNetworkMatch(enabled: true, interface: .wifi))
        let dock = profile("Dock", AutoConnectNetworkMatch(enabled: true, interface: .ethernet, ethernetSubnets: ["192.0.2.0/24"]))
        let profiles = [office, dock, anyWiFi]

        expect(first(profiles, wifi: "Office") == "Office", "a specific SSID must win over the catch-all below it")
        expect(first(profiles, wifi: "Cafe") == "Any Wi-Fi", "the catch-all must match other networks")
        expect(first([anyWiFi, office], wifi: "Office") == "Any Wi-Fi", "list order decides, so a catch-all above hides later profiles")
        expect(first(profiles, ethernet: ["192.0.2.7"]) == "Dock", "an Ethernet address inside the subnet must match")
        expect(first(profiles, ethernet: ["198.51.100.7"]) == nil, "an Ethernet address outside every subnet must not match")
        expect(first(profiles) == nil, "no network, no profile")
        var disabled = office
        disabled.isEnabled = false
        expect(first([disabled, anyWiFi], wifi: "Office") == "Any Wi-Fi", "a disabled profile must be skipped")
        var inner = AutoConnectNetworkMatch(interface: .wifi)
        inner.enabled = false
        expect(first([profile("Inner off", inner)], wifi: "Cafe") == "Inner off", "the profile's own flag decides, not the match's")

        expect(NetworkProfile.parseDNSServers("1.1.1.1, 2606:4700:4700::1111 9.9.9.9") == ["1.1.1.1", "2606:4700:4700::1111", "9.9.9.9"],
               "IPv4 and IPv6 servers separated by commas or spaces must parse")
        func shadow(_ p: NetworkProfile, _ list: [NetworkProfile]) -> String? {
            NetworkProfileResolver.shadowingProfile(of: p, in: list)?.name
        }
        expect(shadow(office, [office, dock, anyWiFi]) == nil, "the first profile is never shadowed")
        expect(shadow(office, [anyWiFi, office]) == "Any Wi-Fi", "a catch-all above a specific SSID shadows it")
        expect(shadow(anyWiFi, [office, anyWiFi]) == nil, "a specific SSID above a catch-all does not shadow it")
        expect(shadow(dock, [anyWiFi, dock]) == nil, "Wi-Fi above does not cover an Ethernet profile")
        let both = profile("Both", AutoConnectNetworkMatch(enabled: true, interface: .both))
        expect(shadow(anyWiFi, [both, anyWiFi]) == "Both", "any network above covers a Wi-Fi profile")
        expect(shadow(both, [anyWiFi, both]) == nil, "Wi-Fi above does not cover a profile that also matches Ethernet")
        var off = anyWiFi
        off.isEnabled = false
        expect(shadow(office, [off, office]) == nil, "a disabled profile above shadows nothing")
        expect(NetworkProfile.parseDNSServers("") == [], "empty text means leave DNS alone")
        expect(NetworkProfile.parseDNSServers("dns.example.com") == nil, "host names must be refused")
        expect(NetworkProfile.parseDNSServers("1.1.1.1;reboot") == nil, "shell punctuation must be refused")
        expect(NetworkProfile.parseDNSServers("1.1.1.1 999.1.1.1") == nil, "one bad address must refuse the whole list")
        expect(NetworkProfile.parseDNSServers((1...9).map { "10.0.0.\($0)" }.joined(separator: " ")) == nil, "more than eight servers must be refused")
        for preset in DNSPreset.all {
            expect(NetworkProfile.parseDNSServers(preset.servers.joined(separator: " ")) == preset.servers,
                   "preset \(preset.name) must hold valid addresses")
        }

        let saved = NetworkProfile(name: "Home", match: AutoConnectNetworkMatch(enabled: true, interface: .both, wifiSSIDs: ["Home"],
                                                                                 ethernetSubnets: ["192.0.2.0/24"]),
                                   dnsServers: ["9.9.9.9"], shortcutName: "Home mode")
        let decoded = try JSONDecoder().decode(NetworkProfile.self, from: JSONEncoder().encode(saved))
        expect(decoded == saved, "a profile must survive a JSON round trip")
        let minimal = try JSONDecoder().decode(NetworkProfile.self, from: Data(#"{"id":"7B1E4C52-0F6A-4D8B-9C3E-1A2B3C4D5E6F","name":"Old"}"#.utf8))
        expect(minimal.isEnabled && minimal.dnsServers.isEmpty && minimal.shortcutName == nil && minimal.match.interface == .wifi,
               "a file with only an id and a name must load with safe defaults")

        let tunnelID = UUID()
        let withActions = NetworkProfile(name: "Cafe", tunnelActions: [ProfileTunnelAction(tunnelID: tunnelID, kind: .connect)])
        let roundTrip = try JSONDecoder().decode(NetworkProfile.self, from: JSONEncoder().encode(withActions))
        expect(roundTrip.tunnelActions == [ProfileTunnelAction(tunnelID: tunnelID, kind: .connect)], "tunnel actions must survive a JSON round trip")
        expect(minimal.tunnelActions.isEmpty, "a profile saved before tunnel actions existed must load with none")

        var withProxy = NetworkProfile(name: "Office")
        var proxy = ProxySettings(mode: .manual)
        proxy.web = ProxyEndpoint(host: "proxy.example.com", port: 8080)
        proxy.bypass = ["*.local"]
        withProxy.proxy = proxy
        let proxyRoundTrip = try JSONDecoder().decode(NetworkProfile.self, from: JSONEncoder().encode(withProxy))
        expect(proxyRoundTrip.proxy == proxy, "a profile's proxy must survive a JSON round trip")
        expect(minimal.proxy == nil, "a profile saved before proxies existed must leave the proxy alone")

        print("PASS: network profiles match in list order, validate DNS servers and survive a JSON round trip")
    }
}
