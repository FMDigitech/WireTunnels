import Darwin
import Foundation
import SystemConfiguration

/// macOS requests AAAA records only while some network service publishes IPv6 state, and
/// wg-quick's utun publishes none: on an IPv4-only network a full IPv6 tunnel carries IPv6
/// traffic but resolves no IPv6-only hostname (issue #45). This publishes an IPv6 service
/// for each running tunnel that routes `::/0`. Split tunnels are skipped because configd
/// would install an IPv6 default route through the tunnel.
/// shortcut: configd's reading of these keys is undocumented and changed in Ventura (Router became
/// required); if a macOS release ignores them, the post-registration check logs it, update serviceValue.
final class IPv6ServiceRegistrar {
    static let shared = IPv6ServiceRegistrar()
    static let keyPattern = "State:/Network/Service/WireTunnels-[^/]+/IPv6"
    static func key(for interface: String) -> String { "State:/Network/Service/WireTunnels-\(interface)/IPv6" }

    private let queue = DispatchQueue(label: "com.fmdigitech.wiretunnels.ipv6-service")
    // Temporary values are dropped by configd when this session ends, so a crashed helper
    // never leaves macOS believing it still has IPv6; a restarted helper re-adds them.
    private let store = SCDynamicStoreCreate(nil, "WireTunnels IPv6 services" as CFString, nil, nil)

    /// `configPaths` maps each running utun to its runtime config, as RuntimeConfigLocator returns it.
    func reconcile(configPaths: [String: String]) {
        queue.sync {
            guard let store else {
                NSLog("IPv6 service registration unavailable: dynamic store could not be opened")
                return
            }
            var desired: [String: NSDictionary] = [:]
            for (interface, path) in configPaths {
                guard let config = try? String(contentsOfFile: path, encoding: .utf8),
                      Self.routesAllIPv6(config: config),
                      let value = Self.serviceValue(interface: interface, addresses: Self.addresses(of: interface))
                else { continue }
                desired[Self.key(for: interface)] = value as NSDictionary
            }
            var present: [String: NSDictionary] = [:]
            for key in (SCDynamicStoreCopyKeyList(store, Self.keyPattern as CFString) as? [String]) ?? [] {
                present[key] = SCDynamicStoreCopyValue(store, key as CFString) as? NSDictionary ?? [:]
            }
            let plan = Self.plan(desired: desired, present: present)
            for key in plan.remove where !SCDynamicStoreRemoveValue(store, key as CFString) {
                NSLog("IPv6 service %@ could not be removed: %s", key, SCErrorString(SCError()))
            }
            for key in plan.add where !SCDynamicStoreAddTemporaryValue(store, key as CFString, desired[key]!) {
                NSLog("IPv6 service %@ could not be published: %s", key, SCErrorString(SCError()))
            }
            guard !plan.add.isEmpty else { return }
            // configd recomputes the global state asynchronously after a service changes.
            queue.asyncAfter(deadline: .now() + 3) {
                if SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) == nil {
                    NSLog("IPv6 service published for %@ but macOS reports no IPv6 state; AAAA lookups stay disabled on this macOS version",
                          plan.add.joined(separator: ", "))
                } else {
                    NSLog("IPv6 service published for %@", plan.add.joined(separator: ", "))
                }
            }
        }
    }

    /// A changed value is removed and added again: a temporary value cannot be overwritten in place.
    static func plan(desired: [String: NSDictionary], present: [String: NSDictionary]) -> (remove: [String], add: [String]) {
        let remove = present.filter { desired[$0.key] != $0.value }.map(\.key).sorted()
        let add = desired.filter { present[$0.key] != $0.value }.map(\.key).sorted()
        return (remove, add)
    }

    /// Mirrors wg-quick: `::/0` in a peer's AllowedIPs routes all IPv6 unless `Table = off`.
    static func routesAllIPv6(config: String) -> Bool {
        var section = ""
        var routesAll = false
        var tableOff = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.lowercased(); continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            if section == "[interface]", key == "table" { tableOff = parts[1].lowercased() == "off" }
            if section == "[peer]", key == "allowedips",
               parts[1].split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "::/0" }) {
                routesAll = true
            }
        }
        return routesAll && !tableOff
    }

    /// Nil without a non-link-local address. Router is the first address's prefix network,
    /// as in the variant reported working on utun; configd ignores a service without one.
    static func serviceValue(interface: String, addresses: [(bytes: [UInt8], prefix: Int)]) -> [String: Any]? {
        guard let first = addresses.first else { return nil }
        let router = first.bytes.enumerated().map { index, byte -> UInt8 in
            let bits = min(max(first.prefix - index * 8, 0), 8)
            return byte & UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
        }
        return [
            "Addresses": addresses.map { text($0.bytes) },
            "PrefixLength": addresses.map { $0.prefix },
            "InterfaceName": interface,
            "Router": text(router),
        ]
    }

    private static func text(_ bytes: [UInt8]) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = bytes.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
        return String(cString: buffer)
    }

    private static func addresses(of interface: String) -> [(bytes: [UInt8], prefix: Int)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result: [(bytes: [UInt8], prefix: Int)] = []
        var cursor = list
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            guard String(cString: entry.ifa_name) == interface,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET6),
                  let mask = entry.ifa_netmask else { continue }
            let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
            }
            if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { continue } // link-local
            let prefix = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { $0.reduce(0) { $0 + $1.nonzeroBitCount } }
            }
            result.append((bytes, prefix))
        }
        return result
    }
}
