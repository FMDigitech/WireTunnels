import Foundation
import Darwin

/// A numeric IPv4 or IPv6 network. Parsing never performs a DNS lookup.
struct IPSubnet {
    let canonicalCIDR: String
    private let networkBytes: [UInt8]
    private let prefixLength: Int

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[1].isEmpty,
              parts[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let prefix = Int(parts[1]),
              let bytes = Self.numericAddress(String(parts[0])),
              prefix <= bytes.count * 8 else { return nil }

        let network = Self.mask(bytes, prefixLength: prefix)
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = bytes.count == 4 ? AF_INET : AF_INET6
        let formatted = network.withUnsafeBytes { pointer in
            inet_ntop(family, pointer.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        guard formatted else { return nil }
        canonicalCIDR = "\(String(cString: buffer))/\(prefix)"
        networkBytes = network
        prefixLength = prefix
    }

    func contains(_ address: String) -> Bool {
        var numeric = address
        if address.contains("%") {
            let parts = address.split(separator: "%", omittingEmptySubsequences: false)
            guard networkBytes.count == 16, parts.count == 2, !parts[1].isEmpty,
                  parts[1].utf8.allSatisfy({
                      ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                          || ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 45 || $0 == 46
                  }) else { return false }
            numeric = String(parts[0])
        }
        guard let bytes = Self.numericAddress(numeric), bytes.count == networkBytes.count else {
            return false
        }
        return Self.mask(bytes, prefixLength: prefixLength) == networkBytes
    }

    private static func numericAddress(_ text: String) -> [UInt8]? {
        guard !text.utf8.contains(0), !text.contains("%") else { return nil }
        // Darwin accepts zero-padded IPv4 octets; require unambiguous decimal
        // octets, including an IPv4 tail embedded in an IPv6 literal.
        if text.contains(".") {
            let dotted = text.split(separator: ":", omittingEmptySubsequences: false).last ?? ""
            let octets = dotted.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ octet in
                !octet.isEmpty && octet.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
                    && (octet.count == 1 || octet.first != "0")
                    && Int(octet).map({ $0 <= 255 }) == true
            }) else { return nil }
        }
        for (family, length) in [(AF_INET, 4), (AF_INET6, 16)] {
            var bytes = [UInt8](repeating: 0, count: length)
            let result = text.withCString { string in
                bytes.withUnsafeMutableBytes { pointer in
                    inet_pton(family, string, pointer.baseAddress)
                }
            }
            if result == 1 { return bytes }
        }
        return nil
    }

    private static func mask(_ bytes: [UInt8], prefixLength: Int) -> [UInt8] {
        bytes.enumerated().map { index, byte in
            let bits = min(8, max(0, prefixLength - index * 8))
            return bits == 0 ? 0 : byte & (UInt8.max << (8 - bits))
        }
    }
}
