import Foundation
import UserNotifications

final class InventoryHelperFixture: NSObject, WireguardHelperProtocol {
    var requests: [InventoryRoutingRequest] = []
    var events: [String] = []
    var pendingReply: ((Bool, String?) -> Void)?
    var pauseInventory = false
    var active = false
    var config: ParsedConfig?
    var generation: UUID?
    var allowedIPs: [String] = []
    func startTunnel(named name: String, reply: @escaping (Bool, String?) -> Void) {
        events.append("start"); active = true; reply(true, nil)
    }
    func stopTunnel(named name: String, reply: @escaping (Bool, String?) -> Void) {
        events.append("stop"); active = false; reply(true, nil)
    }
    private func dump() -> String {
        guard active, let config, let peer = config.peerPublicKey,
              let privateKey = config.privateKey, let local = WireGuardKey.publicKey(fromPrivateKey: privateKey) else { return "" }
        let ips = allowedIPs.isEmpty ? config.allowedIPs : allowedIPs
        return "utun123\t(private)\t\(local)\t51820\toff\n" +
            "utun123\t\(peer)\t(none)\t198.51.100.1:51820\t\(ips.joined(separator: ","))\t0\t0\t0\toff\n"
    }
    func runWgShow(reply: @escaping (String?, String?) -> Void) { reply(dump(), nil) }
    func runtimeStatusSnapshot(reply: @escaping (Data?, String?) -> Void) {
        reply(try? JSONEncoder().encode(WireGuardStatusSnapshot(output: dump(), configPaths: [:])), nil)
    }
    func commandDiagnostics(reply: @escaping (Data?, String?) -> Void) { reply(Data("[]".utf8), nil) }
    func recoverDNSState(reply: @escaping (Bool, String?) -> Void) { reply(true, nil) }
    func readManagedConfig(id: String, authorization: Data, reply: @escaping (Data?, String?) -> Void) {
        preconditionFailure("Unexpected helper call: readManagedConfig")
    }
    func generateKeyPair(reply: @escaping (String?, String?, String?) -> Void) {
        preconditionFailure("Unexpected helper call: generateKeyPair")
    }
    func stageConfig(named name: String, contents: Data, reply: @escaping (Bool, String?) -> Void) {
        config = WireGuardConfigParser().parse(string: String(decoding: contents, as: UTF8.self))
        allowedIPs = config?.allowedIPs ?? []; events.append("stage"); reply(true, nil)
    }
    func listManagedTunnels(reply: @escaping (Data?, String?) -> Void) {
        preconditionFailure("Unexpected helper call: listManagedTunnels")
    }
    func installManagedTunnel(named name: String, contents: Data, authorization: Data, reply: @escaping (Bool, String?) -> Void) {
        preconditionFailure("Unexpected helper call: installManagedTunnel")
    }
    func updateManagedTunnel(id: String, name: String, contents: Data?, policy: Data, autoConnectRule: Data, authorization: Data, reply: @escaping (Bool, String?) -> Void) {
        preconditionFailure("Unexpected helper call: updateManagedTunnel")
    }
    func deleteManagedTunnel(id: String, authorization: Data, reply: @escaping (Bool, String?) -> Void) {
        preconditionFailure("Unexpected helper call: deleteManagedTunnel")
    }
    func stageManagedConfig(id: String, reply: @escaping (String?, String?) -> Void) {
        preconditionFailure("Unexpected helper call: stageManagedConfig")
    }
    func markManagedTunnelConnected(id: String, reply: @escaping (Bool, String?) -> Void) {
        preconditionFailure("Unexpected helper call: markManagedTunnelConnected")
    }
    func markManagedTunnelDisconnected(id: String, reply: @escaping (Bool, String?) -> Void) {
        preconditionFailure("Unexpected helper call: markManagedTunnelDisconnected")
    }
    func listManagedTunnelUsers(id: String, authorization: Data, reply: @escaping (Data?, String?) -> Void) {
        preconditionFailure("Unexpected helper call: listManagedTunnelUsers")
    }
    func getSystemSettings(reply: @escaping (Data?, String?) -> Void) {
        preconditionFailure("Unexpected helper call: getSystemSettings")
    }
    func setSystemSettings(settings: Data, authorization: Data, reply: @escaping (Bool, String?) -> Void) {
        preconditionFailure("Unexpected helper call: setSystemSettings")
    }
    func syncKillSwitch(entries: Data, reply: @escaping (Bool, String?) -> Void) {
        events.append("kill-switch"); reply(true, nil)
    }
    func syncSplitDNS(entries: Data, reply: @escaping (Bool, String?) -> Void) {
        events.append("dns"); reply(true, nil)
    }
    func syncRoutes(ownerId: String, entries: Data, reply: @escaping (Bool, String?) -> Void) {
        preconditionFailure("Unexpected helper call: syncRoutes")
    }
    func updateInventoryRouting(request: Data, reply: @escaping (Bool, String?) -> Void) {
        do {
            let decoded = try JSONDecoder().decode(InventoryRoutingRequest.self, from: request)
            requests.append(decoded); events.append(decoded.action.rawValue)
            if decoded.action == .protect { generation = decoded.generation }
            if decoded.action == .apply {
                guard generation == decoded.generation else { reply(false, "stale"); return }
                allowedIPs = try IPPrefix.normalized(decoded.staticPrefixes + decoded.discoveredPrefixes)
            }
            if pauseInventory { pendingReply = reply } else { reply(true, nil) }
        } catch { reply(false, error.localizedDescription) }
    }
    func toolStatus(reply: @escaping (Bool, String?) -> Void) {
        preconditionFailure("Unexpected helper call: toolStatus")
    }
    func helperVersion(reply: @escaping (String) -> Void) {
        preconditionFailure("Unexpected helper call: helperVersion")
    }
    func helperProtocolRevision(reply: @escaping (String) -> Void) {
        preconditionFailure("Unexpected helper call: helperProtocolRevision")
    }
}

@MainActor
private final class SilentInventoryNotifications: NotificationDelivering {
    func requestAuthorization() async throws -> Bool { false }
    func add(_ request: UNNotificationRequest) async throws {}
}

extension InventoryRoutingTests {
    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw InventoryError.operation("FAILED: app operation did not finish") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor
    static func appIntegration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("example.conf")
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        try """
        [Interface]
        PrivateKey = \(key)
        Address = 192.0.2.1/32
        [Peer]
        PublicKey = \(key)
        Endpoint = 198.51.100.1:51820
        AllowedIPs = 192.0.2.0/24
        """.write(to: file, atomically: true, encoding: .utf8)
        let parsed = try WireGuardConfigParser().parse(contentsOf: file)
        var tunnel = Tunnel(name: "Inventory", configPath: file.path)
        tunnel.publicKey = parsed.peerPublicKey
        tunnel.localPublicKey = WireGuardKey.publicKey(fromPrivateKey: key)
        tunnel.endpoint = parsed.endpoint
        tunnel.allowedIPs = ["203.0.113.99/32"]
        let helper = InventoryHelperFixture()
        let repository = TunnelRepository(file: directory.appendingPathComponent("tunnels.json"))
        let defaults = UserDefaults(suiteName: "wiretunnels.inventory.tests." + UUID().uuidString)!
        let manager = TunnelManager(commandService: WireGuardCommandService(helper: helper),
            networkMonitor: NetworkMonitorService(startMonitoring: false), repository: repository,
            configStorage: ConfigStorageService(configDirectory: directory),
            log: LogService(logFile: directory.appendingPathComponent("test.log"), defaults: defaults),
            notificationService: NotificationService(defaults: defaults, delivery: SilentInventoryNotifications()),
            automaticallyInitialize: false)
        manager.tunnels = [tunnel]
        // Connecting requires installed, verified tools and an initialized app.
        func executable(_ name: String) throws -> String {
            let file = directory.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file.path
        }
        manager.environment.helperInstalled = true; manager.environment.binariesInstalled = true
        manager.environment.wgPath = try executable("wg"); manager.environment.wgQuickPath = try executable("wg-quick")
        manager.environment.wireguardGoPath = try executable("wireguard-go")
        manager.isInitialized = true
        let command = InventoryCommand(executable: "/usr/bin/printf", arguments: ["203.0.113.1\\n2001:db8::1\\n"])

        // Delay a real XPC-boundary reply: saving must reserve the real manager's tunnel.
        helper.pauseInventory = true
        let save = Task { try await manager.updateInventoryCommand(for: tunnel, command: command) }
        try await waitUntil { helper.pendingReply != nil }
        await manager.connectTunnel(tunnel)
        try check(!helper.events.contains("start"), "connect cannot race a pending settings save")
        helper.pauseInventory = false; helper.pendingReply?(true, nil); helper.pendingReply = nil
        try await save.value
        helper.events = []
        await manager.connectTunnel(manager.tunnels[0])
        try await waitUntil { manager.tunnels[0].inventoryUpdatedAt != nil }
        try check(helper.events.first == "stage" && helper.events.firstIndex(of: "protect")! < helper.events.firstIndex(of: "start")!, "real connect protects before starting the VPN")
        try check(helper.requests.last?.staticPrefixes == ["192.0.2.0/24"], "static base is read from saved config")
        try check(manager.tunnels[0].allowedIPs == ["192.0.2.0/24", "203.0.113.1/32", "2001:db8::1/128"], "real app applies command output")
        try check(repository.load()[0].inventoryAllowedIPs == ["203.0.113.1/32", "2001:db8::1/128"], "successful inventory reaches disk")
        try await waitUntil { !manager.refreshingInventories.contains(tunnel.id) }
        helper.events = []
        await manager.handleSystemWake()
        try await waitUntil { !manager.refreshingInventories.contains(tunnel.id) }
        try check(helper.events.first == "protect" && helper.events.firstIndex(of: "stop")! < helper.events.firstIndex(of: "start")! && helper.events.lastIndex(of: "apply")! > helper.events.firstIndex(of: "start")!, "real wake reconnect closes protection before teardown and restores cached routes after start")
        try check(manager.tunnels[0].isActive, "wake reconnect remains active")
        let count = helper.requests.count
        manager.tunnels[0].inventoryCommand = InventoryCommand(executable: "/usr/bin/false", arguments: [])
        await manager.refreshInventory(for: tunnel)
        try check(helper.requests.count == count && manager.tunnels[0].inventoryAllowedIPs.count == 2 && manager.inventoryErrors[tunnel.id] != nil, "failed command retains cache and leaves helper untouched")

        manager.tunnels[0].inventoryCommand = InventoryCommand(executable: "/bin/sleep", arguments: ["10"])
        let refresh = Task { await manager.refreshInventory(for: tunnel) }
        try await waitUntil { manager.refreshingInventories.contains(tunnel.id) }
        helper.events = []
        await manager.disconnectTunnel(manager.tunnels[0])
        await refresh.value
        try check(helper.events.first == "protect" && helper.events.contains("stop"), "real disconnect closes protection before stopping")
        try check(!manager.tunnels[0].isActive && helper.requests.last?.action == .protect, "disconnect cancels pending inventory")

        // Removal is authorized by the root policy ID, independently of the private key file.
        try FileManager.default.removeItem(at: file)
        try await manager.updateInventoryCommand(for: manager.tunnels[0], command: nil)
        try check(helper.requests.last?.action == .remove && repository.load()[0].inventoryCommand == nil, "missing config cannot trap persistent protection")
    }
}
