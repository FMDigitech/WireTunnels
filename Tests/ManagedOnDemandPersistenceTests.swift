import Foundation

@main
struct ManagedOnDemandPersistenceTests {
    static func main() throws {
        let json = Data(#"{"connect":{"enabled":true,"interface":"ethernet","wifiSSIDs":[],"ethernetSubnets":["192.0.2.0/24","fd00:1234::/64"]},"disconnect":{"enabled":true,"interface":"both","wifiSSIDs":["Synthetic guest network"],"ethernetSubnets":["198.51.100.0/25"]}}"#.utf8)
        let stored = try JSONDecoder().decode(ManagedAutoConnectRule.self, from: json)
        let reloaded = try JSONDecoder().decode(AutoConnectRule.self, from: JSONEncoder().encode(stored))
        precondition(reloaded.connect.ethernetSubnets == ["192.0.2.0/24", "fd00:1234::/64"],
                     "The helper dropped the Ethernet connect filter and widened it to any Ethernet network")
        precondition(reloaded.disconnect.ethernetSubnets == ["198.51.100.0/25"],
                     "The helper dropped the independent Ethernet disconnect filter")
        precondition(reloaded.disconnect.wifiSSIDs == ["Synthetic guest network"])

        let legacy = Data(#"{"enabled":true,"interface":"ethernet","action":"disconnect","wifiSSIDs":[]}"#.utf8)
        let oldStored = try JSONDecoder().decode(ManagedAutoConnectRule.self, from: legacy)
        let old = try JSONDecoder().decode(AutoConnectRule.self, from: JSONEncoder().encode(oldStored))
        precondition(old.disconnect.enabled && old.disconnect.matchesAnyEthernet,
                     "Old shared Ethernet rules must keep their existing any-network behavior")
        precondition(!old.connect.enabled)

        let legacyWithFilter = Data(#"{"enabled":true,"interface":"ethernet","action":"connect","ethernetSubnets":["203.0.113.0/24"]}"#.utf8)
        let oldFiltered = try JSONDecoder().decode(ManagedAutoConnectRule.self, from: legacyWithFilter)
        let filtered = try JSONDecoder().decode(AutoConnectRule.self, from: JSONEncoder().encode(oldFiltered))
        precondition(filtered.connect.ethernetSubnets == ["203.0.113.0/24"])

        let malformed = Data(#"{"connect":{"enabled":true,"interface":"ethernet","ethernetSubnets":["invalid CIDR"]}}"#.utf8)
        let raw = try JSONDecoder().decode(ManagedAutoConnectRule.self, from: malformed)
        let invalid = try JSONDecoder().decode(AutoConnectRule.self, from: JSONEncoder().encode(raw))
        precondition(invalid.connect.ethernetSubnets == ["invalid CIDR"] && !invalid.connect.matchesAnyEthernet,
                     "Unknown filter values must not be discarded into an unrestricted rule")
        print("PASS: helper storage preserves separate Ethernet filters, legacy behavior, and invalid restrictive entries")
    }
}
