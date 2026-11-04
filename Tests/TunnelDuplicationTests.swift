import Foundation

@main
struct TunnelDuplicationTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ConfigStorageService(configDirectory: root)
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let content = """
        [Interface]
        PrivateKey = \(key)
        Address = 192.168.89.2/32
        DNS = 192.168.88.1

        [Peer]
        PublicKey = \(Data(repeating: 2, count: 32).base64EncodedString())
        AllowedIPs = 192.168.88.0/24
        Endpoint = vpn.example:13231
        """
        let path = try storage.saveConfig(name: "vpn", content: content)
        var source = Tunnel(name: "vpn", configPath: path.path)
        source.isActive = true
        source.isFavorite = true
        source.runtimeConfigPath = "/runtime/vpn.conf"
        source.interfaceName = "utun7"
        source.connectedAt = Date()
        source.lastHandshake = Date()
        source.rxBytes = 400
        source.txBytes = 200
        source.autostart = true
        source.autoConnectRule.connect.enabled = true
        source.autoConnectRule.connect.wifiSSIDs = ["Test network"]
        source.autoConnectRule.disconnect.enabled = true
        source.killSwitchEnabled = true
        source.ipFamilyLeakWarningAcknowledged = true
        source.excludedRoutes = ["192.0.2.0/24"]
        source.splitDNSDomains = ["example"]
        source.speedTestURL = "https://example.com/test"
        // Live metrics must not replace saved configuration in the duplicate.
        source.endpoint = "192.0.2.1:13231"
        source.allowedIPs = ["0.0.0.0/0"]
        let duplicator = TunnelDuplicationService(configStorage: storage)
        let copy = try duplicator.duplicate(source, existingTunnels: [source])
        guard copy.id != source.id, copy.name == "vpn_copy", copy.configPath != source.configPath,
              try storage.readConfig(at: URL(fileURLWithPath: copy.configPath)) == content,
              try storage.readConfig(at: path) == content else { fatalError("Duplicate changed the source or failed to copy its config") }
        guard !copy.isActive, copy.runtimeConfigPath == nil, copy.interfaceName == nil,
              copy.connectedAt == nil, copy.lastHandshake == nil, copy.rxBytes == 0, copy.txBytes == 0,
              !copy.isFavorite, !copy.autostart, !copy.autoConnectRule.enabled,
              copy.scope == .personal, copy.managedPolicy == nil else { fatalError("Duplicate inherited connection or automation state") }
        guard copy.endpoint == "vpn.example:13231", copy.allowedIPs == ["192.168.88.0/24"],
              copy.address == ["192.168.89.2/32"], copy.dns == ["192.168.88.1"],
              copy.localPublicKey == WireGuardKey.publicKey(fromPrivateKey: key),
              copy.killSwitchEnabled, copy.ipFamilyLeakWarningAcknowledged, copy.excludedRoutes == source.excludedRoutes,
              copy.splitDNSDomains == source.splitDNSDomains, copy.speedTestURL == source.speedTestURL,
              copy.autoConnectRule.connect.wifiSSIDs == ["Test network"] else { fatalError("Duplicate lost saved config or routing settings") }
        let attributes = try FileManager.default.attributesOfItem(atPath: copy.configPath)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { fatalError("Duplicate config is not private") }
        let second = try duplicator.duplicate(source, existingTunnels: [source, copy])
        guard second.name == "vpn_copy_2", second.id != copy.id else { fatalError("Repeated duplication reused an identity") }
        // File-only collisions and shared runtime names must also be avoided.
        _ = try storage.saveConfig(name: "vpn_copy_3", content: content)
        let shared = Tunnel(name: "shared", configPath: "/managed/vpn_copy_4.conf")
        let fifth = try duplicator.duplicate(source, existingTunnels: [source, copy, second, shared])
        guard fifth.name == "vpn_copy_5" else { fatalError("Duplicate reused an existing file or managed config alias") }
        let displayCollision = Tunnel(name: "VPN_COPY_7", configPath: "/managed/unrelated.conf")
        let eighth = try duplicator.duplicate(source, existingTunnels: [source, copy, second, shared, fifth, displayCollision], reservedConfigNames: ["vpn_copy_6"])
        guard eighth.name == "vpn_copy_8" else { fatalError("Duplicate ignored active runtime aliases or case-insensitive display names") }
        let edited = content.replacingOccurrences(of: "AllowedIPs = 192.168.88.0/24", with: "AllowedIPs = 0.0.0.0/0")
        _ = try storage.saveConfig(name: copy.name, content: edited, replacingExisting: true)
        guard try storage.readConfig(at: path) == content,
              try storage.readConfig(at: URL(fileURLWithPath: second.configPath)) == content else { fatalError("Editing one copy changed another profile") }
        var longSource = source
        longSource.name = "Office VPN (東京)"
        let namedCopy = try duplicator.duplicate(longSource, existingTunnels: [source])
        guard namedCopy.name == "Office VPN (東京)_copy" else { fatalError("Duplication replaced display-name characters") }
        longSource.name = String(repeating: "a", count: 50)
        let longCopy = try duplicator.duplicate(longSource, existingTunnels: [source])
        guard longCopy.name == String(repeating: "a", count: 45) + "_copy",
              URL(fileURLWithPath: longCopy.configPath).deletingPathExtension().lastPathComponent.utf8.count <= 15 else { fatalError("Duplicate failed long-name limits") }
        var managed = source
        managed.scope = .managed
        let count = storage.listConfigs().count
        do {
            _ = try duplicator.duplicate(managed, existingTunnels: [])
            fatalError("Managed config was copied outside its protected store")
        } catch TunnelDuplicationError.personalTunnelsOnly { }
        guard storage.listConfigs().count == count else { fatalError("Failed duplicate left a config behind") }
        var invalid = source
        invalid.configPath = try storage.saveConfig(name: "invalid", content: content + "\nPostUp = echo unsafe\n").path
        let beforeInvalid = storage.listConfigs().count
        do {
            _ = try duplicator.duplicate(invalid, existingTunnels: [])
            fatalError("Duplicate accepted a privileged hook")
        } catch TunnelDuplicationError.invalidConfiguration(let errors) {
            guard errors.contains(.unsupportedDirective("PostUp")) else { fatalError("Wrong validation error") }
        }
        var missing = source
        missing.configPath = root.appendingPathComponent("absent.conf").path
        do {
            _ = try duplicator.duplicate(missing, existingTunnels: [])
            fatalError("Duplicate succeeded without a source config")
        } catch CocoaError.fileReadNoSuchFile { }
        guard storage.listConfigs().count == beforeInvalid else { fatalError("Failed duplication left a file behind") }
        print("PASS: duplication copies config independently, resets runtime state, and avoids name collisions")
    }
}
