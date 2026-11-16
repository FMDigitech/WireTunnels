import CryptoKit
import Foundation

/// wg-quick treats a `DNS =` entry that is not an IP address as a search domain
/// (set while the tunnel is up, restored on disconnect), so the app mirrors that rule.
nonisolated enum WireGuardDNS {
    static func isAddress(_ value: String) -> Bool {
        value.range(of: "^[0-9.]+$", options: .regularExpression) != nil || value.contains(":")
    }

    static func servers(_ entries: [String]) -> [String] { entries.filter(isAddress) }

    static func searchDomains(_ entries: [String]) -> [String] { entries.filter { !isAddress($0) } }

    /// Lower-cased domain without a wildcard or dots at the ends, or nil when it is not a valid name.
    static func normalizedDomain(_ raw: String) -> String? {
        var domain = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if domain.hasPrefix("*.") { domain.removeFirst(2) }
        while domain.hasPrefix(".") { domain.removeFirst() }
        while domain.hasSuffix(".") { domain.removeLast() }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard !domain.isEmpty, domain.utf8.count <= 253,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                      && label.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }
              }) else { return nil }
        return domain
    }

    /// The `DNS =` value for the typed servers and search domains. Invalid search domains are
    /// left out and reported, so a typo can never reach wg-quick.
    static func compose(servers: String, searchDomains: String) -> (line: String, invalidDomains: [String]) {
        func entries(_ text: String) -> [String] {
            text.split { $0 == "," || $0.isWhitespace }.map(String.init)
        }
        var seen = Set<String>(), invalid: [String] = [], domains: [String] = []
        for entry in entries(searchDomains) {
            guard let domain = normalizedDomain(entry) else { invalid.append(entry); continue }
            if seen.insert(domain).inserted { domains.append(domain) }
        }
        return ((entries(servers) + domains).joined(separator: ", "), invalid)
    }
}

nonisolated enum IPFamily: String, CaseIterable, Hashable {
    case ipv4, ipv6

    var displayName: String { self == .ipv4 ? "IPv4" : "IPv6" }
    var defaultRoute: String { self == .ipv4 ? "0.0.0.0/0" : "::/0" }
}

/// AllowedIPs and Address entries are compared by their parsed bytes, so `0::/0` matches `::/0`.
nonisolated enum IPFamilyRouting {
    private struct Entry {
        let family: IPFamily
        let bytes: [UInt8]
        let prefix: Int?
    }

    private static func parse(_ entry: String) -> Entry? {
        // wg-quick drops everything from "#"; the config parser keeps it in the value.
        let parts = String(entry.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(parts[0].split(separator: "%", maxSplits: 1).first ?? "")
        let prefix = parts.count == 2 ? Int(parts[1]) : nil
        if parts.count == 2 && prefix == nil { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return Entry(family: .ipv4, bytes: withUnsafeBytes(of: &v4) { Array($0) }, prefix: prefix)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return Entry(family: .ipv6, bytes: withUnsafeBytes(of: &v6) { Array($0) }, prefix: prefix)
        }
        return nil
    }

    static func family(of entry: String) -> IPFamily? { parse(entry)?.family }

    /// The family's default route, or both of its /1 halves as wg-quick installs them.
    static func routesAll(_ family: IPFamily, allowedIPs: [String]) -> Bool {
        var halves = Set<UInt8>()
        for entry in allowedIPs.compactMap(parse) where entry.family == family {
            if entry.prefix == 0 { return true }
            if entry.prefix == 1 { halves.insert(entry.bytes[0] & 0x80) }
        }
        return halves.count == 2
    }

    static func routedAllFamilies(allowedIPs: [String]) -> Set<IPFamily> {
        Set(IPFamily.allCases.filter { routesAll($0, allowedIPs: allowedIPs) })
    }

    static func hasAddress(_ family: IPFamily, in addresses: [String]) -> Bool {
        addresses.contains { parse($0)?.family == family }
    }

    /// Families the physical network can reach the internet with: global unicast IPv6
    /// (2000::/3) and any IPv4 address outside link-local 169.254.0.0/16.
    static func internetFamilies(ofPhysicalAddresses addresses: [String]) -> Set<IPFamily> {
        var families = Set<IPFamily>()
        for entry in addresses.compactMap(parse) {
            switch entry.family {
            case .ipv4 where !(entry.bytes[0] == 169 && entry.bytes[1] == 254): families.insert(.ipv4)
            case .ipv6 where entry.bytes[0] & 0xE0 == 0x20: families.insert(.ipv6)
            default: break
            }
        }
        return families
    }
}

enum WireGuardKey {
    /// Derives the base64 WireGuard public key from a base64 private key (X25519).
    static func publicKey(fromPrivateKey privateKey: String) -> String? {
        guard let raw = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            return nil
        }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }
}

/// Detects wg-quick root command hooks the way wg-quick itself parses a config, so no
/// line can be read as a hook by wg-quick but as something else here. wg-quick's
/// parse_options splits on "\n" only (bash `read` also silently drops NUL bytes),
/// strips everything from the first "#", takes the text before the first "=" — or the
/// whole line when there is none — as the key, trims [[:space:]] and matches
/// case-insensitively, anywhere in the line. All of this works on Unicode scalars, not
/// Characters: Swift folds "\r\n" and "=" + combining mark into single Characters that
/// bash sees as separate bytes. Control characters (other than tab, newline, and a CR
/// ending a CRLF line) are rejected outright because Swift and bash disagree on them.
/// Keep in sync with WireTunnelsHelper/HelperTool.swift.
enum ConfigSafety {
    enum Violation: Equatable {
        case controlCharacter
        case hook(String)
    }

    static let hookDirectives: Set<String> = ["preup", "postup", "predown", "postdown"]

    static func firstViolation(in text: String) -> Violation? {
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            switch scalar.value {
            case 0x09, 0x0A:
                continue
            case 0x0D where index + 1 < scalars.count && scalars[index + 1] == "\n":
                continue
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
                return .controlCharacter
            default:
                continue
            }
        }
        for line in text.unicodeScalars.split(separator: "\n") {
            let stripped = line.prefix { $0 != "#" }
            let keyScalars = stripped.firstIndex(of: "=").map { stripped[..<$0] } ?? stripped
            let key = String(String.UnicodeScalarView(keyScalars))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if hookDirectives.contains(key) {
                return .hook(key)
            }
        }
        return nil
    }
}

/// The extra keys AmneziaWG's `awg setconf` accepts (amneziawg-tools at the pinned revision,
/// Scripts/wireguard-versions.env). A config that uses any of them needs awg, not wg.
/// `awg` exits on a malformed value, so values are checked here, at import, with the same
/// rules it applies.
nonisolated enum AmneziaWGKeys {
    enum Kind {
        case uint16
        case uint32Range
        case uint16Range
        case flag
        case text
        case key
    }

    /// Interface keys, in the order they are written back by the basic form.
    static let interfaceKinds: [(name: String, kind: Kind)] = [
        ("Jc", .uint16), ("Jmin", .uint16), ("Jmax", .uint16),
        ("S1", .uint16), ("S2", .uint16), ("S3", .uint16), ("S4", .uint16),
        ("H1", .uint32Range), ("H2", .uint32Range), ("H3", .uint32Range), ("H4", .uint32Range),
        ("I1", .text), ("I2", .text), ("I3", .text), ("I4", .text), ("I5", .text),
        ("HeaderProtectionKey", .key),
        ("ContentPaddingAddition", .uint16Range),
        ("RekeyAfterTime", .uint16Range), ("RekeyTimeout", .uint16Range),
        ("RejectAfterTime", .uint16Range), ("KeepaliveTimeout", .uint16Range),
        ("MaxHandshakeAttempts", .uint16Range),
        ("RandomTrailers", .flag), ("DisableCookies", .flag)
    ]
    static let peerKinds: [(name: String, kind: Kind)] = [("AdvancedSecurity", .flag)]

    static func interfaceKind(of key: String) -> (name: String, kind: Kind)? {
        interfaceKinds.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    static func peerKind(of key: String) -> (name: String, kind: Kind)? {
        peerKinds.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    static func isValid(_ value: String, kind: Kind) -> Bool {
        switch kind {
        case .uint16: return integer(value, maximum: 65535) != nil
        case .uint32Range: return range(value, maximum: UInt64(UInt32.max))
        case .uint16Range: return range(value, maximum: 65535)
        case .flag:
            return value.caseInsensitiveCompare("on") == .orderedSame
                || value.caseInsensitiveCompare("off") == .orderedSame
                || integer(value, maximum: UInt64(UInt32.max)) != nil
        case .text:
            return !value.isEmpty
        case .key:
            return Data(base64Encoded: value)?.count == 32
        }
    }

    private static func integer(_ text: String, maximum: UInt64) -> UInt64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = UInt64(text), number <= maximum else { return nil }
        return number
    }

    /// "N" or "N-M" with N <= M, as awg's u32_range_from_string reads it.
    private static func range(_ text: String, maximum: UInt64) -> Bool {
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let low = integer(parts[0], maximum: maximum) else { return false }
        if parts.count == 1 { return true }
        guard let high = integer(parts[1], maximum: maximum) else { return false }
        return high >= low
    }
}

struct ParsedConfig {
    // Interface section
    var privateKey: String?
    var address: [String] = []
    var dns: [String] = []
    var listenPort: Int?

    /// AmneziaWG-only keys, as written (name, value), in file order. Empty for plain WireGuard.
    var amneziaInterface: [(name: String, value: String)] = []
    var amneziaPeer: [(name: String, value: String)] = []
    var usesAmneziaWG: Bool { !amneziaInterface.isEmpty || !amneziaPeer.isEmpty }

    // Peer section (first peer only for MVP)
    var peerPublicKey: String?
    var presharedKey: String?
    var endpoint: String?
    var allowedIPs: [String] = []
    var persistentKeepalive: Int?

    // Validation
    var validationErrors: [ConfigValidationError] = []
    var warnings: [ConfigWarning] = []
    var isValid: Bool {
        validationErrors.isEmpty
    }
}

enum ConfigValidationError: Equatable, Hashable {
    case missingPrivateKey
    case missingAddress
    case missingPeerPublicKey
    case missingAllowedIPs
    case unsupportedDirective(String)
    case controlCharacters
    case invalidAmneziaValue(String)

    var message: String {
        switch self {
        case .missingPrivateKey:
            return "PrivateKey is missing"
        case .missingAddress:
            return "Address is missing"
        case .missingPeerPublicKey:
            return "Peer PublicKey is missing"
        case .missingAllowedIPs:
            return "AllowedIPs is missing"
        case .unsupportedDirective(let directive):
            return "\(directive) is not supported because it executes commands with root privileges"
        case .controlCharacters:
            return "Configuration contains control characters"
        case .invalidAmneziaValue(let key):
            return "The AmneziaWG parameter \(key) has an invalid value"
        }
    }
}

enum ConfigWarning: String {
    case missingDNS = "DNS not configured"
    case missingEndpoint = "Endpoint not specified"
    case fullTunnel = "AllowedIPs includes 0.0.0.0/0 — full tunnel mode"
    case multiplePeers = "Multiple peers found — only first peer used in MVP"
    case ipv4RoutedWithoutAddress = "AllowedIPs routes all IPv4 traffic but there is no IPv4 Address, so IPv4 will leak"
    case ipv6RoutedWithoutAddress = "AllowedIPs routes all IPv6 traffic but there is no IPv6 Address, so IPv6 will leak"
}

final class WireGuardConfigParser {
    func parse(contentsOf url: URL) throws -> ParsedConfig {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(string: contents)
    }

    func parse(string: String) -> ParsedConfig {
        var config = ParsedConfig()
        var currentSection = ""
        var peerCount = 0

        // The helper rejects the same things; flagging them here gives a clear error at import.
        switch ConfigSafety.firstViolation(in: string) {
        case .controlCharacter?:
            config.validationErrors.append(.controlCharacters)
        case .hook(let key)?:
            let canonicalName: String
            switch key {
            case "preup": canonicalName = "PreUp"
            case "postup": canonicalName = "PostUp"
            case "predown": canonicalName = "PreDown"
            default: canonicalName = "PostDown"
            }
            config.validationErrors.append(.unsupportedDirective(canonicalName))
        case nil:
            break
        }

        for rawLine in string.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") {
                currentSection = line.lowercased()
                if currentSection == "[peer]" { peerCount += 1 }
                continue
            }

            let parts = line.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1...].joined(separator: "=").trimmingCharacters(in: .whitespaces)
            let normalizedKey = key.lowercased()

            if currentSection == "[interface]" {
                switch normalizedKey {
                case "privatekey": config.privateKey = nonEmpty(value)
                case "address":
                    config.address += nonEmptyList(value)
                case "dns":
                    config.dns += nonEmptyList(value)
                case "listenport": config.listenPort = Int(value)
                default:
                    if let known = AmneziaWGKeys.interfaceKind(of: key) {
                        record(known, value: value, peer: false, into: &config)
                    }
                }
            } else if currentSection == "[peer]" && peerCount == 1 {
                switch normalizedKey {
                case "publickey": config.peerPublicKey = nonEmpty(value)
                case "presharedkey": config.presharedKey = nonEmpty(value)
                case "endpoint": config.endpoint = nonEmpty(value)
                case "allowedips":
                    config.allowedIPs += nonEmptyList(value)
                case "persistentkeepalive": config.persistentKeepalive = Int(value)
                default:
                    if let known = AmneziaWGKeys.peerKind(of: key) {
                        record(known, value: value, peer: true, into: &config)
                    }
                }
            }
        }

        if config.privateKey == nil { config.validationErrors.append(.missingPrivateKey) }
        if config.address.isEmpty { config.validationErrors.append(.missingAddress) }
        if config.peerPublicKey == nil { config.validationErrors.append(.missingPeerPublicKey) }
        if config.allowedIPs.isEmpty { config.validationErrors.append(.missingAllowedIPs) }

        if config.dns.isEmpty { config.warnings.append(.missingDNS) }
        if config.endpoint == nil { config.warnings.append(.missingEndpoint) }
        if config.allowedIPs.contains("0.0.0.0/0") { config.warnings.append(.fullTunnel) }
        for family in IPFamily.allCases where IPFamilyRouting.routesAll(family, allowedIPs: config.allowedIPs)
            && !IPFamilyRouting.hasAddress(family, in: config.address) {
            config.warnings.append(family == .ipv4 ? .ipv4RoutedWithoutAddress : .ipv6RoutedWithoutAddress)
        }
        if peerCount > 1 { config.warnings.append(.multiplePeers) }

        return config
    }

    /// awg strips everything from the first "#" (a trailing comment) before reading a value,
    /// so a value is checked and stored the same way.
    private func record(
        _ known: (name: String, kind: AmneziaWGKeys.Kind),
        value: String,
        peer: Bool,
        into config: inout ParsedConfig
    ) {
        let cleaned = (value.firstIndex(of: "#").map { String(value[..<$0]) } ?? value)
            .trimmingCharacters(in: .whitespaces)
        if peer {
            config.amneziaPeer.append((known.name, cleaned))
        } else {
            config.amneziaInterface.append((known.name, cleaned))
        }
        if !AmneziaWGKeys.isValid(cleaned, kind: known.kind) {
            config.validationErrors.append(.invalidAmneziaValue(known.name))
        }
    }

    private func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func nonEmptyList(_ value: String) -> [String] {
        value.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
