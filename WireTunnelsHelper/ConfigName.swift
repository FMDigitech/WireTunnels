import CryptoKit
import Foundation

enum ConfigName {
    static func displayName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
    }

    /// Keep this mapping identical to ConfigStorageService.fileBaseName.
    /// wg-quick accepts only 1-15 ASCII interface-name characters in filenames.
    static func fileBaseName(_ displayName: String) -> String {
        // Match Swift's canonical equality without changing the display name.
        let name = self.displayName(displayName).precomposedStringWithCanonicalMapping
        let base = name.hasSuffix(".conf") ? String(name.dropLast(".conf".count)) : name
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=+.-"
        )
        let safeBase = base
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .reduce("") { $0 + String($1) }
            .replacingOccurrences(of: "..", with: "__")
        // A trailing dot would create ".." when the .conf extension is appended.
        guard base.isEmpty || base.hasSuffix(".") || safeBase != base || base.utf8.count > 15 else { return base }
        var hash: UInt32 = 2166136261
        for byte in (base.isEmpty ? name : base).utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        let suffix = String(format: "%06x", hash & 0xFFFFFF)
        let prefix = safeBase.isEmpty ? "tunnel" : String(safeBase.prefix(15 - suffix.count - 1))
        return "\(prefix)-\(suffix)"
    }

    static func publicKey(fromPrivateKey privateKey: String) -> String? {
        guard let raw = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Removes `DNS =` from [Interface] so wg-quick doesn't set DNS system-wide.
    static func strippingDNS(from contents: Data) -> Data {
        guard let text = String(data: contents, encoding: .utf8) else { return contents }
        var inInterface = false
        let lines = text.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inInterface = trimmed.caseInsensitiveCompare("[Interface]") == .orderedSame
                return true
            }
            guard inInterface else { return true }
            let key = trimmed.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return key.caseInsensitiveCompare("DNS") != .orderedSame
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func nonEmptyList(_ value: String) -> [String] {
        value.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
