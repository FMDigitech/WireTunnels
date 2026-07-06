import Foundation

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
    private static let privilegedHookNames: Set<String> = [
        "preup", "postup", "predown", "postdown"
    ]

    func parse(contentsOf url: URL) throws -> ParsedConfig {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(string: contents)
    }

    func parse(string: String) -> ParsedConfig {
        var config = ParsedConfig()
        var currentSection = ""
        var peerCount = 0

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

            if Self.privilegedHookNames.contains(normalizedKey) {
                let canonicalName: String
                switch normalizedKey {
                case "preup": canonicalName = "PreUp"
                case "postup": canonicalName = "PostUp"
                case "predown": canonicalName = "PreDown"
                default: canonicalName = "PostDown"
                }
                let error = ConfigValidationError.unsupportedDirective(canonicalName)
                if !config.validationErrors.contains(error) {
                    config.validationErrors.append(error)
                }
                continue
            }

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
