import Foundation

enum AutoConnectNetworkMatcher {
    static func matches(
        _ rule: AutoConnectNetworkMatch,
        isOnEthernet: Bool,
        ethernetAddresses: [String],
        isOnWiFi: Bool,
        currentSSID: String?
    ) -> Bool {
        guard rule.enabled else { return false }
        let ethernet = isOnEthernet && rule.interface != .wifi
            && (rule.matchesAnyEthernet || rule.ethernetSubnets.contains { text in
                guard let subnet = IPSubnet(text) else { return false }
                return ethernetAddresses.contains(where: subnet.contains)
            })
        let wifi = isOnWiFi && rule.interface != .ethernet
            && (rule.matchesAnyWiFi || currentSSID.map(rule.wifiSSIDs.contains) == true)
        return ethernet || wifi
    }
}
