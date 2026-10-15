import Foundation
import Darwin

struct InterfaceAddressSnapshot {
    let ethernetAddresses: [String]
    let primaryInterfaceName: String?
    let primaryIPv4Address: String?

    func primaryIPv4Changed(after previous: Self?) -> Bool {
        guard let previous, let primaryInterfaceName, let primaryIPv4Address else { return false }
        return previous.primaryInterfaceName == primaryInterfaceName
            && previous.primaryIPv4Address != nil
            && previous.primaryIPv4Address != primaryIPv4Address
    }

    func requiresRuleEvaluation(after previous: Self?) -> Bool {
        ethernetAddresses != (previous?.ethernetAddresses ?? []) || primaryIPv4Changed(after: previous)
    }
}

enum InterfaceAddressCollector {
    struct Entry {
        let interfaceName: String
        let family: Int32
        let flags: UInt32
        let address: String?
    }

    static func addresses(on interfaceNames: Set<String>, entries: [Entry]) -> [String] {
        let requiredFlags = UInt32(IFF_UP | IFF_RUNNING)
        return Set(entries.compactMap { entry -> String? in
            guard interfaceNames.contains(entry.interfaceName),
                  entry.family == AF_INET || entry.family == AF_INET6,
                  entry.flags & requiredFlags == requiredFlags,
                  entry.flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.address, !address.isEmpty
            else { return nil }
            return address
        }).sorted()
    }

    /// Interface names must come from the path's wired-Ethernet interfaces.
    /// Numeric-only lookup reads local addresses without DNS or network traffic.
    static func addresses(on interfaceNames: Set<String>) -> [String] {
        guard !interfaceNames.isEmpty else { return [] }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var entries: [Entry] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let interface = current.pointee
            guard let name = interface.ifa_name,
                  interfaceNames.contains(String(cString: name)),
                  let address = interface.ifa_addr
            else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            entries.append(Entry(interfaceName: String(cString: name), family: family,
                                 flags: interface.ifa_flags, address: String(cString: host)))
        }
        return addresses(on: interfaceNames, entries: entries)
    }
}
