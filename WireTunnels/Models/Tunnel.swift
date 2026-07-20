import Foundation

enum TunnelScope: String, Codable, Hashable {
    case personal
    case managed
}

struct ManagedTunnelPolicy: Codable, Equatable, Hashable {
    var usersCanConnect: Bool
    var usersCanDisconnect: Bool
    var killSwitchEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case usersCanConnect
        case usersCanDisconnect
        case killSwitchEnabled
    }

    init(usersCanConnect: Bool = true, usersCanDisconnect: Bool = true, killSwitchEnabled: Bool = false) {
        self.usersCanConnect = usersCanConnect
        self.usersCanDisconnect = usersCanDisconnect
        self.killSwitchEnabled = killSwitchEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usersCanConnect = try container.decodeIfPresent(Bool.self, forKey: .usersCanConnect) ?? true
        usersCanDisconnect = try container.decodeIfPresent(Bool.self, forKey: .usersCanDisconnect) ?? true
        killSwitchEnabled = try container.decodeIfPresent(Bool.self, forKey: .killSwitchEnabled) ?? false
    }
}

struct ManagedTunnelUserSession: Identifiable, Codable, Equatable, Hashable {
    var uid: Int
    var username: String
    var connectedAt: Date

    var id: Int { uid }
}

struct Tunnel: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var configPath: String          // ~/Library/.../configs/name.conf
    var runtimeConfigPath: String?  // /Library/.../runtime/name.conf (legacy wireguard/ accepted for stop)
    var interfaceName: String?      // utun0, etc. — same as config filename without .conf
    var isActive: Bool
    var isFavorite: Bool
    var autostart: Bool
    var autoConnectRule: AutoConnectRule
    var killSwitchEnabled: Bool
    var address: [String]?      // [Interface] Address — tunnel's own IPs
    var allowedIPs: [String]
    var dns: [String]
    var endpoint: String?
    var publicKey: String?
    var lastHandshake: Date?
    var rxBytes: Int64
    var txBytes: Int64
    var connectedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var scope: TunnelScope
    var managedPolicy: ManagedTunnelPolicy?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case configPath
        case runtimeConfigPath
        case interfaceName
        case isActive
        case isFavorite
        case autostart
        case autoConnectRule
        case killSwitchEnabled
        case address
        case allowedIPs
        case dns
        case endpoint
        case publicKey
        case lastHandshake
        case rxBytes
        case txBytes
        case connectedAt
        case createdAt
        case updatedAt
        case scope
        case managedPolicy
    }

    init(name: String, configPath: String) {
        self.id = UUID()
        self.name = name
        self.configPath = configPath
        self.runtimeConfigPath = nil
        self.interfaceName = nil
        self.isActive = false
        self.isFavorite = false
        self.autostart = false
        self.autoConnectRule = AutoConnectRule()
        self.killSwitchEnabled = false
        self.allowedIPs = []
        self.dns = []
        self.endpoint = nil
        self.publicKey = nil
        self.lastHandshake = nil
        self.rxBytes = 0
        self.txBytes = 0
        self.connectedAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.scope = .personal
        self.managedPolicy = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        configPath = try container.decode(String.self, forKey: .configPath)
        runtimeConfigPath = try container.decodeIfPresent(String.self, forKey: .runtimeConfigPath)
        interfaceName = try container.decodeIfPresent(String.self, forKey: .interfaceName)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        autostart = try container.decode(Bool.self, forKey: .autostart)
        autoConnectRule = try container.decodeIfPresent(AutoConnectRule.self, forKey: .autoConnectRule)
            ?? AutoConnectRule()
        killSwitchEnabled = try container.decodeIfPresent(Bool.self, forKey: .killSwitchEnabled) ?? false
        address = try container.decodeIfPresent([String].self, forKey: .address)
        allowedIPs = try container.decode([String].self, forKey: .allowedIPs)
        dns = try container.decode([String].self, forKey: .dns)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        lastHandshake = try container.decodeIfPresent(Date.self, forKey: .lastHandshake)
        rxBytes = try container.decode(Int64.self, forKey: .rxBytes)
        txBytes = try container.decode(Int64.self, forKey: .txBytes)
        connectedAt = try container.decodeIfPresent(Date.self, forKey: .connectedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        scope = try container.decodeIfPresent(TunnelScope.self, forKey: .scope) ?? .personal
        managedPolicy = try container.decodeIfPresent(ManagedTunnelPolicy.self, forKey: .managedPolicy)
    }

    /// Whether the kill switch is armed for this tunnel, regardless of scope —
    /// personal tunnels use their own flag, managed tunnels defer to the
    /// admin-controlled policy pushed from the shared helper store.
    var isKillSwitchEnabled: Bool {
        scope == .managed ? (managedPolicy?.killSwitchEnabled ?? false) : killSwitchEnabled
    }
}
