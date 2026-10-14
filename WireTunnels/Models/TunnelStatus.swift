import Foundation

struct WireGuardStatusSnapshot: Codable {
    let output: String
    let configPaths: [String: String]
}

struct TunnelStatus: Equatable {
    let interfaceName: String
    let publicKey: String
    let listenPort: Int
    let peers: [PeerStatus]
    var runtimeConfigPath: String? = nil
}

struct PeerStatus: Equatable {
    let publicKey: String
    let endpoint: String?
    let allowedIPs: [String]
    let lastHandshake: Date?
    let rxBytes: Int64
    let txBytes: Int64
    let persistentKeepalive: Int?
}

/// Decides which live WireGuard interface belongs to which configured tunnel.
///
/// On macOS `wg show` reports kernel utun names, which aren't stable across
/// reconnects, so a tunnel is identified by its keys instead:
/// - the local public key (derived from the tunnel's own `PrivateKey`) identifies
///   *this client* — several clients of one server share the server key, host and port;
/// - the peer (server) public key, and the endpoint port when known, tell servers
///   or listening ports apart;
/// - one interface is assigned to at most one tunnel, and tunnels with a known
///   local key are resolved first so key-less ones can't take their interface.
enum InterfaceMatcher {
    struct Candidate {
        var peerPublicKey: String?
        var localPublicKey: String?
        var endpoint: String?
        /// Last learned interface name, or the config's file name.
        var interfaceHint: String
        var configName: String? = nil
    }

    static func assign(_ candidates: [Candidate], statuses: [String: TunnelStatus]) -> [Int: TunnelStatus] {
        let ordered = statuses.values.sorted { $0.interfaceName < $1.interfaceName }
        var claimed = Set<String>()
        var matched: [Int: TunnelStatus] = [:]

        let order = candidates.indices.sorted { lhs, rhs in
            (candidates[lhs].localPublicKey != nil ? 0 : 1) < (candidates[rhs].localPublicKey != nil ? 0 : 1)
        }
        // Reserve exact runtime aliases for every profile before falling back to
        // keys. Profiles can share both keys while using different routes.
        for index in order {
            let candidate = candidates[index]
            let byRuntimeConfig = candidate.configName.flatMap { name in
                ordered.first { status in
                    guard let path = status.runtimeConfigPath else { return false }
                    return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent == name
                }
            }
            let byName = byRuntimeConfig
                ?? candidate.configName.flatMap { statuses[$0] }
                ?? statuses[candidate.interfaceHint]
            let runtimeName = byName?.runtimeConfigPath.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            }
            if let byName, !claimed.contains(byName.interfaceName),
               candidate.configName == nil || runtimeName == nil || runtimeName == candidate.configName,
               candidate.peerPublicKey == nil || isOurs(byName, candidate) {
                claimed.insert(byName.interfaceName)
                matched[index] = byName
            }
        }
        for index in order where matched[index] == nil {
            let candidate = candidates[index]
            let byName = statuses[candidate.interfaceHint]
            let status: TunnelStatus?
            if candidate.peerPublicKey != nil {
                if let byName, !claimed.contains(byName.interfaceName), isOurs(byName, candidate) {
                    status = byName
                } else {
                    status = ordered.first { !claimed.contains($0.interfaceName) && isOurs($0, candidate) }
                }
            } else {
                // No peer key to verify against (e.g. not parsed yet): trust the name.
                status = byName.flatMap { claimed.contains($0.interfaceName) ? nil : $0 }
            }
            if let status {
                claimed.insert(status.interfaceName)
                matched[index] = status
            }
        }
        return matched
    }

    private static func isOurs(_ status: TunnelStatus, _ candidate: Candidate) -> Bool {
        guard let peerKey = candidate.peerPublicKey else { return false }
        if let localKey = candidate.localPublicKey, status.publicKey != localKey { return false }
        let configuredPort = candidate.endpoint.flatMap { parseEndpoint($0)?.port }
        return status.peers.contains { peer in
            guard peer.publicKey == peerKey else { return false }
            guard let configuredPort,
                  let peerPort = peer.endpoint.flatMap({ parseEndpoint($0)?.port }) else { return true }
            return peerPort == configuredPort
        }
    }

    static func parseEndpoint(_ endpoint: String) -> (host: String, port: Int)? {
        if endpoint.hasPrefix("["), let closeBracket = endpoint.firstIndex(of: "]") {
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<closeBracket])
            let rest = endpoint[endpoint.index(after: closeBracket)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let lastColon = endpoint.lastIndex(of: ":") else { return nil }
        let host = String(endpoint[..<lastColon])
        guard let port = Int(endpoint[endpoint.index(after: lastColon)...]) else { return nil }
        return (host, port)
    }
}
