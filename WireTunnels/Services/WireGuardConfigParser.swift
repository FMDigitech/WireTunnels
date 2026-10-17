import CryptoKit
import Foundation

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

struct ParsedConfig {
    // Interface section
    var privateKey: String?
    var address: [String] = []
    var dns: [String] = []
    var listenPort: Int?

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
        }
    }
}

enum ConfigWarning: String {
    case missingDNS = "DNS not configured"
    case missingEndpoint = "Endpoint not specified"
    case fullTunnel = "AllowedIPs includes 0.0.0.0/0 — full tunnel mode"
    case multiplePeers = "Multiple peers found — only first peer used in MVP"
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
                    config.address = nonEmptyList(value)
                case "dns":
                    config.dns = nonEmptyList(value)
                case "listenport": config.listenPort = Int(value)
                default: break
                }
            } else if currentSection == "[peer]" && peerCount == 1 {
                switch normalizedKey {
                case "publickey": config.peerPublicKey = nonEmpty(value)
                case "presharedkey": config.presharedKey = nonEmpty(value)
                case "endpoint": config.endpoint = nonEmpty(value)
                case "allowedips":
                    config.allowedIPs = nonEmptyList(value)
                case "persistentkeepalive": config.persistentKeepalive = Int(value)
                default: break
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
        if peerCount > 1 { config.warnings.append(.multiplePeers) }

        return config
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
