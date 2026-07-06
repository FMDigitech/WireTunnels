import Foundation

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
        self.allowedIPs = []
        self.dns = []
        self.endpoint = nil
        self.publicKey = nil
        self.lastHandshake = nil
        self.rxBytes = 0
        self.txBytes = 0
        self.createdAt = Date()
        self.updatedAt = Date()
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
    }
}
