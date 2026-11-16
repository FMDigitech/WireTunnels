import Darwin
import Foundation

/// A machine to wake with a Wake-on-LAN magic packet.
struct WakeTarget: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// Six hex pairs, `aa:bb:cc:dd:ee:ff`.
    var macAddress: String
    /// The address the packet is sent to. The limited broadcast reaches the local network only.
    var broadcastAddress = "255.255.255.255"
    /// Optional host that answers ping once the machine is up. Without it, "packet sent" is all that is known.
    var checkAddress: String? = nil
}

enum MagicPacket {
    /// The six bytes of a MAC written with `:` or `-` between the pairs, or nil.
    static func parseMAC(_ text: String) -> [UInt8]? {
        let pairs = text.trimmingCharacters(in: .whitespaces).split(omittingEmptySubsequences: false) { $0 == ":" || $0 == "-" }
        guard pairs.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for pair in pairs {
            guard pair.count == 2, pair.allSatisfy(\.isHexDigit), let byte = UInt8(pair, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    static func normalizedMAC(_ text: String) -> String? {
        parseMAC(text)?.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Six 0xFF bytes followed by the MAC sixteen times: 102 bytes.
    static func packet(for mac: String) -> Data? {
        guard let bytes = parseMAC(mac) else { return nil }
        return Data(repeating: 0xFF, count: 6) + Data((0..<16).flatMap { _ in bytes })
    }

    static func isIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1
    }

    /// Sends the packet over UDP port 9 as a broadcast. Returns false when the socket refuses it.
    static func send(to target: WakeTarget) -> Bool {
        guard let packet = packet(for: target.macAddress), isIPv4(target.broadcastAddress) else { return false }
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        inet_pton(AF_INET, target.broadcastAddress, &address.sin_addr)
        let sent = packet.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, buffer.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == packet.count
    }
}

/// One port forward over SSH, kept alive by the app.
/// - `local`: `listenPort` on this Mac reaches `targetHost:targetPort` as seen from the SSH server.
/// - `remote`: `listenPort` on the SSH server (loopback only) reaches `targetHost:targetPort` as seen from this Mac.
/// - `dynamic`: `listenPort` on this Mac is a SOCKS5 proxy that sends traffic out through the SSH server.
struct SSHForward: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable { case local, remote, dynamic }

    var kind = Kind.local
    var listenPort: Int
    var targetHost = ""
    var targetPort = 0

    init(kind: Kind = .local, listenPort: Int, targetHost: String = "", targetPort: Int = 0) {
        self.kind = kind
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    private enum CodingKeys: String, CodingKey { case kind, listenPort, targetHost, targetPort }
    // Keys written by the first version, which only had local forwards.
    private enum LegacyKeys: String, CodingKey { case localPort, remoteHost, remotePort }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let port = try container.decodeIfPresent(Int.self, forKey: .listenPort) {
            kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .local
            listenPort = port
            targetHost = try container.decodeIfPresent(String.self, forKey: .targetHost) ?? ""
            targetPort = try container.decodeIfPresent(Int.self, forKey: .targetPort) ?? 0
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            kind = .local
            listenPort = try legacy.decode(Int.self, forKey: .localPort)
            targetHost = try legacy.decode(String.self, forKey: .remoteHost)
            targetPort = try legacy.decode(Int.self, forKey: .remotePort)
        }
    }

    /// How the editor writes and reads it: `8080:host:80`, `R:9000:localhost:3000` or `D:1080`.
    var text: String {
        switch kind {
        case .local: return "\(listenPort):\(targetHost):\(targetPort)"
        case .remote: return "R:\(listenPort):\(targetHost):\(targetPort)"
        case .dynamic: return "D:\(listenPort)"
        }
    }

    static func parse(_ line: String) -> SSHForward? {
        var parts = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var kind = Kind.local
        if let first = parts.first, first == "R" || first == "D" {
            kind = first == "R" ? .remote : .dynamic
            parts.removeFirst()
        }
        switch kind {
        case .dynamic:
            guard parts.count == 1, let port = Int(parts[0]) else { return nil }
            return SSHForward(kind: .dynamic, listenPort: port)
        case .local, .remote:
            guard parts.count == 3, let listen = Int(parts[0]), let target = Int(parts[2]) else { return nil }
            return SSHForward(kind: kind, listenPort: listen, targetHost: parts[1], targetPort: target)
        }
    }
}

struct SSHTunnel: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var host: String
    var user: String? = nil
    var port = 22
    var forwards: [SSHForward]
    /// Restart ssh with a growing delay when it exits.
    var reconnects = true
}

enum SSHTunnelCommand {
    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
    private static let userCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && !host.hasPrefix("-")
            && host.unicodeScalars.allSatisfy { hostCharacters.contains($0) }
    }

    static func isValidUser(_ user: String) -> Bool {
        !user.isEmpty && user.count <= 64 && !user.hasPrefix("-") && user.unicodeScalars.allSatisfy { userCharacters.contains($0) }
    }

    static func isValidPort(_ port: Int) -> Bool { (1...65535).contains(port) }

    /// Why the tunnel cannot be started, or nil when it is well formed.
    static func problem(with tunnel: SSHTunnel) -> String? {
        if tunnel.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the tunnel a name." }
        if !isValidHost(tunnel.host) { return "The host must be a name or address without spaces or a leading dash." }
        if let user = tunnel.user, !isValidUser(user) { return "The user name has characters ssh would read as options." }
        if !isValidPort(tunnel.port) { return "The SSH port must be between 1 and 65535." }
        if tunnel.forwards.isEmpty { return "Add at least one port forward." }
        // Local and SOCKS forwards listen on this Mac, remote ones on the server: two separate sets of ports.
        var seenHere = Set<Int>(), seenThere = Set<Int>()
        for forward in tunnel.forwards {
            if !isValidPort(forward.listenPort) { return "Ports must be between 1 and 65535." }
            if forward.kind != .dynamic {
                if !isValidPort(forward.targetPort) { return "Ports must be between 1 and 65535." }
                if !isValidHost(forward.targetHost) { return "The forward's target host is not valid." }
            }
            let isNew = forward.kind == .remote ? seenThere.insert(forward.listenPort).inserted
                                                : seenHere.insert(forward.listenPort).inserted
            if !isNew { return "Port \(forward.listenPort) is used twice." }
        }
        return nil
    }

    /// Arguments for `/usr/bin/ssh`. Forwards bind to 127.0.0.1 only, on both ends. `BatchMode` stops ssh from
    /// waiting for a password nobody can type, and `ExitOnForwardFailure` makes a busy port an error
    /// instead of a tunnel that looks up but forwards nothing.
    static func arguments(for tunnel: SSHTunnel) -> [String]? {
        guard problem(with: tunnel) == nil else { return nil }
        var arguments = ["-N", "-T",
                         "-o", "BatchMode=yes",
                         "-o", "ExitOnForwardFailure=yes",
                         "-o", "ServerAliveInterval=15",
                         "-o", "ServerAliveCountMax=3",
                         "-o", "ConnectTimeout=10",
                         "-p", String(tunnel.port)]
        for forward in tunnel.forwards {
            switch forward.kind {
            case .local: arguments += ["-L", "127.0.0.1:\(forward.listenPort):\(forward.targetHost):\(forward.targetPort)"]
            case .remote: arguments += ["-R", "127.0.0.1:\(forward.listenPort):\(forward.targetHost):\(forward.targetPort)"]
            case .dynamic: arguments += ["-D", "127.0.0.1:\(forward.listenPort)"]
            }
        }
        arguments += ["--", tunnel.user.map { "\($0)@\(tunnel.host)" } ?? tunnel.host]
        return arguments
    }

    /// Seconds to wait before restart number `attempt` (0 for the first): 2, 4, 8 ... capped at 60.
    static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(60, 2 * pow(2, Double(min(max(attempt, 0), 5))))
    }

    /// A run that lasted this long counts as having worked, so the backoff starts over.
    static let stableRunDuration: TimeInterval = 30
}
