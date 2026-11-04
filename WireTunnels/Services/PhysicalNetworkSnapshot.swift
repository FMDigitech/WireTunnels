import Foundation
import SystemConfiguration

/// Connected physical links and their local addresses, independent of VPN routes.
struct PhysicalNetworkSnapshot: Equatable {
    struct Interface {
        enum Kind { case wifi, ethernet }
        let name: String
        let kind: Kind
        let isLinkActive: Bool
        let addresses: [String]
    }

    let wifiInterfaces: [String]
    let ethernetInterfaces: [String]
    let ethernetAddresses: [String]
    let connectedAddresses: [String]
    let ipv4AddressesByInterface: [String: [String]]
    let primaryInterfaceName: String?
    let primaryIPv4Address: String?

    var isOnWiFi: Bool { !wifiInterfaces.isEmpty }
    var isOnEthernet: Bool { !ethernetInterfaces.isEmpty }
    var addressSnapshot: InterfaceAddressSnapshot {
        InterfaceAddressSnapshot(ethernetAddresses: ethernetAddresses,
            primaryInterfaceName: primaryInterfaceName, primaryIPv4Address: primaryIPv4Address)
    }

    init(interfaces: [Interface], preferredPrimaryInterface: String?) {
        let connected = interfaces.filter { $0.isLinkActive && !$0.addresses.isEmpty }
        wifiInterfaces = Array(Set(connected.filter { $0.kind == .wifi }.map(\.name))).sorted()
        ethernetInterfaces = Array(Set(connected.filter { $0.kind == .ethernet }.map(\.name))).sorted()
        ethernetAddresses = Array(Set(connected.filter { $0.kind == .ethernet }.flatMap(\.addresses))).sorted()
        connectedAddresses = Array(Set(connected.flatMap(\.addresses))).sorted()
        ipv4AddressesByInterface = Dictionary(grouping: connected, by: \.name).mapValues { interfaces in
            Array(Set(interfaces.flatMap(\.addresses).filter { !$0.contains(":") })).sorted()
        }
        let primary = connected.first { $0.name == preferredPrimaryInterface }
            ?? connected.sorted { $0.name < $1.name }.first
        primaryInterfaceName = primary?.name
        primaryIPv4Address = primary?.addresses.first { !$0.contains(":") }
    }

    func hasIPv4Renewal(after previous: Self?) -> Bool {
        guard let previous else { return false }
        return ipv4AddressesByInterface.contains { name, addresses in
            guard !addresses.isEmpty, let old = previous.ipv4AddressesByInterface[name],
                  !old.isEmpty else { return false }
            return old != addresses
        }
    }

    static func readSystem() -> Self? {
        guard let hardware = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        var interfaces: [Interface] = []
        for interface in hardware {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            let kind: Interface.Kind
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                kind = .wifi
            } else if type == (kSCNetworkInterfaceTypeEthernet as String) {
                kind = .ethernet
            } else {
                continue // utun, loopback, bridges and other virtual interfaces.
            }
            let key = SCDynamicStoreKeyCreateNetworkInterfaceEntity(nil, kSCDynamicStoreDomainState,
                                                                    name as CFString, kSCEntNetLink)
            let link = SCDynamicStoreCopyValue(nil, key) as? [String: Any]
            guard link?[kSCPropNetLinkActive as String] as? Bool == true else { continue }
            interfaces.append(Interface(name: name, kind: kind, isLinkActive: true,
                addresses: InterfaceAddressCollector.addresses(on: [name])))
        }
        var primary: String?
        for entity in [kSCEntNetIPv4, kSCEntNetIPv6] {
            let key = SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, entity)
            let state = SCDynamicStoreCopyValue(nil, key) as? [String: Any]
            if let name = state?[kSCDynamicStorePropNetPrimaryInterface as String] as? String,
               interfaces.contains(where: { $0.name == name && !$0.addresses.isEmpty }) {
                primary = name
                break
            }
        }
        return Self(interfaces: interfaces, preferredPrimaryInterface: primary)
    }
}
