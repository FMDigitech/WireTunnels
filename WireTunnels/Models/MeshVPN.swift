import Foundation
import Darwin

// Mesh VPN clients (Tailscale, NetBird) are driven through their own command line, as the logged-in
// user: WireTunnels never touches their keys, their coordination server or their interfaces. A
// Headscale network is reached with the Tailscale client, so it is handled as Tailscale.
//
// The JSON readers below follow the output of `tailscale status --json` and `netbird status --json`
// as documented by their projects. Every field is optional, so a field that is missing or renamed in
// another release leaves that detail blank instead of failing the whole status.

nonisolated enum MeshVPNKind: String, CaseIterable, Identifiable {
    case tailscale, netbird

    var id: String { rawValue }

    var displayName: String { self == .tailscale ? "Tailscale" : "NetBird" }

    /// Where the command line tool lives. The Tailscale app's own binary works as the CLI.
    var candidatePaths: [String] {
        switch self {
        case .tailscale:
            return ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        case .netbird:
            return ["/opt/homebrew/bin/netbird", "/usr/local/bin/netbird"]
        }
    }

    var statusArguments: [String] { ["status", "--json"] }
    var upArguments: [String] { ["up"] }
    var downArguments: [String] { ["down"] }
    var supportsExitNodes: Bool { self == .tailscale }
}

nonisolated enum MeshVPNState: Equatable {
    case running
    case stopped
    case needsLogin
    case needsApproval
    case starting
    case unknown(String)

    var label: String {
        switch self {
        case .running: return "Connected"
        case .stopped: return "Off"
        case .needsLogin: return "Needs login"
        case .needsApproval: return "Waiting for approval"
        case .starting: return "Starting"
        case .unknown(let value): return value.isEmpty ? "Unknown" : value
        }
    }

    /// Whether turning it on from here can work. A login or an admin approval happens in their own app.
    var canToggle: Bool {
        switch self {
        case .running, .stopped: return true
        default: return false
        }
    }
}

nonisolated struct MeshExitNode: Identifiable, Equatable {
    /// The address passed to the command line, never a free-typed value.
    let id: String
    let name: String
    let online: Bool
    let isActive: Bool
}

/// How a peer is reached, as the client itself reports it. WireTunnels cannot force a direct path.
nonisolated enum MeshPeerPath: String, Equatable {
    case direct = "Direct", relay = "Relay"
}

nonisolated struct MeshPeer: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String?
    let online: Bool
    let path: MeshPeerPath?
}

nonisolated struct MeshVPNStatus: Equatable {
    let kind: MeshVPNKind
    let state: MeshVPNState
    let deviceName: String?
    let addresses: [String]
    let networkName: String?
    let exitNodes: [MeshExitNode]
    let peersOnline: Int?
    let peersTotal: Int?
    let health: [String]
    var peers: [MeshPeer] = []

    var activeExitNode: MeshExitNode? { exitNodes.first(where: { $0.isActive }) }
}

nonisolated enum MeshVPNParser {
    private struct TailscaleNode: Decodable {
        var HostName: String?
        var DNSName: String?
        var TailscaleIPs: [String]?
        var Online: Bool?
        var ExitNode: Bool?
        var ExitNodeOption: Bool?
        var CurAddr: String?
        var Relay: String?
    }

    private struct TailscaleStatus: Decodable {
        struct Tailnet: Decodable { var Name: String?; var MagicDNSSuffix: String? }
        var BackendState: String?
        var AuthURL: String?
        var TailscaleIPs: [String]?
        var Health: [String]?
        var CurrentTailnet: Tailnet?
        var `Self`: TailscaleNode?
        var Peer: [String: TailscaleNode]?
    }

    /// Strips a prefix length: Tailscale prints some addresses as "100.64.0.1/32".
    private static func address(_ text: String) -> String {
        String(text.prefix { $0 != "/" }).trimmingCharacters(in: .whitespaces)
    }

    static func isAddress(_ text: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    private static func displayName(_ node: TailscaleNode) -> String {
        if let host = node.HostName, !host.isEmpty { return host }
        let dns = (node.DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return dns.isEmpty ? (node.TailscaleIPs?.first.map(address) ?? "unnamed") : dns
    }

    static func tailscale(_ data: Data) -> MeshVPNStatus? {
        guard let status = try? JSONDecoder().decode(TailscaleStatus.self, from: data) else { return nil }
        let state: MeshVPNState
        switch status.BackendState ?? "" {
        case "Running": state = .running
        case "Stopped": state = .stopped
        case "NeedsLogin": state = .needsLogin
        case "NeedsMachineAuth": state = .needsApproval
        case "Starting": state = .starting
        case let other: state = .unknown(other)
        }
        let peers = Array((status.Peer ?? [:]).values)
        // A node's own IPv4 address first: that is the one `--exit-node` accepts for sure.
        let exitNodes = peers.filter { $0.ExitNodeOption == true }.compactMap { node -> MeshExitNode? in
            let addresses = (node.TailscaleIPs ?? []).map(address).filter(isAddress)
            guard let id = addresses.first(where: { !$0.contains(":") }) ?? addresses.first else { return nil }
            return MeshExitNode(id: id, name: displayName(node), online: node.Online == true, isActive: node.ExitNode == true)
        }.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        let own = status.Self
        // A peer with a current address is reached directly; one with only a relay goes through it.
        let meshPeers = (status.Peer ?? [:]).map { key, node -> MeshPeer in
            let online = node.Online == true
            let path: MeshPeerPath? = !online ? nil : (node.CurAddr?.isEmpty == false ? .direct : (node.Relay?.isEmpty == false ? .relay : nil))
            return MeshPeer(id: key, name: displayName(node), address: node.TailscaleIPs?.first.map(address), online: online, path: path)
        }.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        return MeshVPNStatus(
            kind: .tailscale, state: state,
            deviceName: own.map(displayName),
            addresses: (own?.TailscaleIPs ?? status.TailscaleIPs ?? []).map(address),
            networkName: status.CurrentTailnet?.MagicDNSSuffix ?? status.CurrentTailnet?.Name,
            exitNodes: exitNodes,
            peersOnline: peers.isEmpty ? nil : peers.filter { $0.Online == true }.count,
            peersTotal: peers.isEmpty ? nil : peers.count,
            health: status.Health ?? [], peers: meshPeers)
    }

    private struct NetBirdStatus: Decodable {
        struct Management: Decodable { var connected: Bool? }
        struct Detail: Decodable { var fqdn: String?; var netbirdIp: String?; var status: String?; var connectionType: String? }
        struct Peers: Decodable { var total: Int?; var connected: Int?; var details: [Detail]? }
        var management: Management?
        var netbirdIp: String?
        var fqdn: String?
        var peers: Peers?
    }

    static func netbird(_ data: Data) -> MeshVPNStatus? {
        guard let status = try? JSONDecoder().decode(NetBirdStatus.self, from: data) else { return nil }
        let connected = status.management?.connected
        return MeshVPNStatus(
            kind: .netbird,
            state: connected == true ? .running : (connected == false ? .stopped : .unknown("")),
            deviceName: status.fqdn.flatMap { $0.isEmpty ? nil : $0 },
            addresses: status.netbirdIp.map { [address($0)] }.map { $0.filter { !$0.isEmpty } } ?? [],
            networkName: nil, exitNodes: [],
            peersOnline: status.peers?.connected, peersTotal: status.peers?.total, health: [],
            peers: (status.peers?.details ?? []).map { peer in
                let online = peer.status?.lowercased() == "connected"
                let path: MeshPeerPath? = !online ? nil : (peer.connectionType?.lowercased().hasPrefix("relay") == true ? .relay : .direct)
                let name = peer.fqdn ?? peer.netbirdIp ?? "unnamed"
                return MeshPeer(id: name, name: name, address: peer.netbirdIp.map(address), online: online, path: path)
            })
    }

    static func parse(_ data: Data, kind: MeshVPNKind) -> MeshVPNStatus? {
        kind == .tailscale ? tailscale(data) : netbird(data)
    }
}

nonisolated enum MeshVPNCommand {
    /// `tailscale set --exit-node=ADDRESS`, or an empty value to stop using one. Only an address that
    /// is an IP literal gets through, so nothing typed or received can add an option.
    static func setExitNode(_ address: String?) -> [String]? {
        guard let address else { return ["set", "--exit-node="] }
        guard MeshVPNParser.isAddress(address) else { return nil }
        return ["set", "--exit-node=\(address)"]
    }
}
