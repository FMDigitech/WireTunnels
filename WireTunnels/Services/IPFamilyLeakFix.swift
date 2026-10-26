import Foundation

/// Stops a leaking family by giving the tunnel a placeholder address of it, so wg-quick's
/// routes for that family install and the server drops the traffic.
nonisolated enum IPFamilyLeakFix {
    enum UnavailableReason: Equatable {
        case routeBypassed, managed, inventoryProtected, busy, dnsUsesFamily
    }

    static func unavailableReason(for leak: IPFamilyLeak, dns: [String], isManaged: Bool,
                                  hasInventory: Bool, isBusy: Bool) -> UnavailableReason? {
        if leak.reason == .routeBypassed { return .routeBypassed }
        if isManaged { return .managed }
        if hasInventory { return .inventoryProtected }
        if isBusy { return .busy }
        // Routing the family into the tunnel would drop every DNS query.
        let servers = WireGuardDNS.servers(dns)
        if !servers.isEmpty, servers.allSatisfy({ IPFamilyRouting.family(of: $0) == leak.family }) {
            return .dnsUsesFamily
        }
        return nil
    }

    static func dnsUnavailableMessage(for family: IPFamily) -> String {
        "The fix is not available because this tunnel's DNS servers use \(family.displayName)."
    }

    /// IPv6: a random RFC 4193 /48. IPv4: a random host in 198.18.0.0/15, which real LANs and VPNs do not use.
    static func placeholderAddress<G: RandomNumberGenerator>(for family: IPFamily, using generator: inout G) -> String {
        switch family {
        case .ipv6:
            let id = (0..<5).map { _ in Int(UInt8.random(in: 0...255, using: &generator)) }
            return String(format: "fd%02x:%x:%x::1/128", id[0], id[1] << 8 | id[2], id[3] << 8 | id[4])
        case .ipv4:
            return "198.\(Int.random(in: 18...19, using: &generator)).\(Int.random(in: 0...255, using: &generator))."
                + "\(Int.random(in: 1...254, using: &generator))/32"
        }
    }

    static func markerComment(for family: IPFamily) -> String {
        let name = family.displayName
        return "# Placeholder address added by WireTunnels to keep \(name) from leaking. Remove it once the tunnel has a real \(name) address."
    }

    /// Adds the placeholder address and the family's default route only where they are missing.
    /// Every other line is kept byte for byte.
    static func apply(to config: String, family: IPFamily, placeholder: String) -> String {
        var lines = config.components(separatedBy: "\n")
        let lineEnd = lines.first?.hasSuffix("\r") == true ? "\r" : ""
        var section = "", peerCount = 0
        var interfaceHeader: Int?, addressLine: Int?, allowedIPsLine: Int?
        var addresses: [String] = [], allowedIPs: [String] = []
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                section = line.lowercased()
                if section == "[peer]" { peerCount += 1 }
                if section == "[interface]" && interfaceHeader == nil { interfaceHeader = index }
                continue
            }
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let values = line[line.index(after: equals)...].prefix { $0 != "#" }
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if section == "[interface]" && key == "address" {
                addressLine = addressLine ?? index
                addresses += values
            } else if section == "[peer]" && peerCount == 1 && key == "allowedips" {
                allowedIPsLine = allowedIPsLine ?? index
                allowedIPs += values
            }
        }

        // AllowedIPs comes first so inserting the comment above Address cannot shift its index.
        if !IPFamilyRouting.routesAll(family, allowedIPs: allowedIPs), let index = allowedIPsLine {
            lines[index] = appending(family.defaultRoute, to: lines[index])
        }
        if !IPFamilyRouting.hasAddress(family, in: addresses) {
            if let index = addressLine {
                lines[index] = appending(placeholder, to: lines[index])
                lines.insert(markerComment(for: family) + lineEnd, at: index)
            } else if let header = interfaceHeader {
                lines.insert(contentsOf: [markerComment(for: family) + lineEnd, "Address = \(placeholder)" + lineEnd],
                             at: header + 1)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func appending(_ value: String, to line: String) -> String {
        let lineEnd = line.hasSuffix("\r") ? "\r" : ""
        var body = lineEnd.isEmpty ? line : String(line.dropLast())
        var comment = ""
        if let hash = body.firstIndex(of: "#") {
            comment = " " + body[hash...]
            body = String(body[..<hash])
        }
        while body.last?.isWhitespace == true { body.removeLast() }
        return body + ", " + value + comment + lineEnd
    }
}
