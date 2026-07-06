import Foundation

struct TunnelStatus: Equatable {
    let interfaceName: String
    let publicKey: String
    let listenPort: Int
    let peers: [PeerStatus]
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
