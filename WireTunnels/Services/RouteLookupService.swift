import Foundation

/// Asks the routing table where public traffic of each family goes, the same unprivileged
/// `route -n get` shellout as `DefaultRouteService`. Lookups never send packets.
nonisolated enum RouteLookupService {
    /// One destination per /1 half that carries public traffic (2000::/3 lies in ::/1).
    static let probeDestinations: [IPFamily: [String]] = [
        .ipv4: ["1.1.1.1", "149.112.112.112"],
        .ipv6: ["2606:4700:4700::1111"],
    ]

    static func parseInterface(fromRouteGetOutput output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("interface:") else { continue }
            let name = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Blocking - call from a background task, not the main actor.
    static func interface(for destination: String, family: IPFamily) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = family == .ipv6 ? ["-n", "get", "-inet6", destination] : ["-n", "get", destination]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        return parseInterface(fromRouteGetOutput: String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    /// Families with a probe that resolves outside every connected tunnel. Failed lookups count as unknown, not as leaks.
    static func bypassedFamilies(_ families: Set<IPFamily>, tunnelInterfaces: Set<String>,
                                 lookup: (String, IPFamily) -> String?) -> Set<IPFamily> {
        Set(families.filter { family in
            (probeDestinations[family] ?? []).contains { destination in
                guard let name = lookup(destination, family) else { return false }
                return name != "lo0" && !tunnelInterfaces.contains(name)
            }
        })
    }
}
