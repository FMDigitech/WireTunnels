import Foundation

// The runner inserts the real manager methods at the markers below. Only helper
// and UI dependencies are substituted; tunnel models and inventory errors are real.
private struct TestLog {
    func info(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {}
}

private enum CommandError: Error {
    case managedTunnelFailed(String)
}

@MainActor
private final class TestCommands {
    var stopped: [String] = []
    var started: [String] = []
    var clearedRoutes: [UUID] = []
    var clearedSessions: [UUID] = []
    var onStop: (() -> Void)?

    func stopTunnel(configPath: String) async throws {
        stopped.append(configPath)
        onStop?()
    }

    func startTunnel(configPath: String) async throws { started.append(configPath) }
    func syncRoutes(ownerId: UUID, entries: [String]) async throws {
        precondition(entries.isEmpty, "A completed stop must remove its exclusion routes")
        clearedRoutes.append(ownerId)
    }
    func markManagedTunnelDisconnected(id: UUID) async throws { clearedSessions.append(id) }
}

@MainActor
private final class TestNetworkMonitor {
    var ssid = "Office"
    var autoConnected: Set<UUID> = []

    func matchesConnect(_ tunnel: Tunnel) -> Bool { matches(tunnel.autoConnectRule.connect) }
    func matchesDisconnect(_ tunnel: Tunnel) -> Bool { matches(tunnel.autoConnectRule.disconnect) }
    private func matches(_ rule: AutoConnectNetworkMatch) -> Bool {
        rule.enabled && rule.interface != .ethernet && (rule.matchesAnyWiFi || rule.wifiSSIDs.contains(ssid))
    }
    func wasAutoConnected(_ id: UUID) -> Bool { autoConnected.contains(id) }
    func markAutoDisconnected(_ id: UUID) { autoConnected.remove(id) }
    func userDidDisconnect(_ id: UUID) { autoConnected.remove(id) }
}

@MainActor
private final class TestFeedback {
    var disconnectedIDs: [UUID] = []
    func begin(_ id: UUID, reconnecting: Bool) {}
    func finish(_ id: UUID) {}
    func completeConnection(_ id: UUID, isActive: Bool) {}
    func disconnected(_ id: UUID) { disconnectedIDs.append(id) }
}

private struct TestNotifications {
    func postDisconnected(tunnelName: String) async throws {}
}

private struct TestChain {
    let id: UUID
}

@MainActor
private final class StopFixture {
    var tunnels: [Tunnel]
    let commandService = TestCommands()
    let networkMonitor = TestNetworkMonitor()
    let connectionFeedback = TestFeedback()
    let notificationService = TestNotifications()
    let log = TestLog()
    var canConnectTunnels = true
    var isShuttingDown = false
    var connectingTunnels: Set<UUID> = []
    var disconnectingTunnels: Set<UUID> = []
    var connectingChains: Set<UUID> = []
    var activeChain: TestChain?
    var killSwitchArmedTunnelIDs: Set<UUID>
    var trafficHistory: [UUID: Int]
    var trafficSnapshots: [UUID: Int]
    var protectedInventories: [UUID] = []
    var saved = 0
    var warningUpdates = 0
    var splitDNSUpdates = 0
    var failures: [String] = []

    init() {
        var tunnel = Tunnel(name: "Synthetic protected tunnel", configPath: "/private/tmp/profile.conf")
        tunnel.scope = .managed
        tunnel.managedPolicy = ManagedTunnelPolicy(killSwitchEnabled: true,
                                                   splitDNSDomains: ["example.test"])
        tunnel.isActive = true
        tunnel.runtimeConfigPath = "/private/tmp/runtime.conf"
        tunnel.interfaceName = "utun42"
        tunnel.connectedAt = Date()
        tunnel.lastHandshake = Date()
        tunnel.rxBytes = 120
        tunnel.txBytes = 80
        tunnel.excludedRoutes = ["203.0.113.0/24"]
        tunnel.autoConnectRule.connect = AutoConnectNetworkMatch(enabled: true, interface: .wifi,
                                                                wifiSSIDs: ["Office"])
        tunnels = [tunnel]
        killSwitchArmedTunnelIDs = [tunnel.id]
        trafficHistory = [tunnel.id: 1]
        trafficSnapshots = [tunnel.id: 1]
        networkMonitor.autoConnected = [tunnel.id]
    }

    func activeOrBusyChain(containing id: UUID) -> TestChain? { activeChain }
    func protectInventory(_ tunnel: Tunnel) async throws { protectedInventories.append(tunnel.id) }
    func disarmKillSwitch(for tunnel: Tunnel) async { killSwitchArmedTunnelIDs.remove(tunnel.id) }
    func savePersonalTunnelsOnly() { saved += 1 }
    func updateWarnings() { warningUpdates += 1 }
    func syncSplitDNSState() async { splitDNSUpdates += 1 }
    func checkIPFamilyRoutes() async {}
    func reportTunnelFailure(_ tunnel: Tunnel, message: String, automatic: Bool) async {
        failures.append(message)
    }
    func restart() async { await reconnectAfterWake(tunnels[0]) }

    // PRODUCTION_STOP_METHODS

    // PRODUCTION_RECONNECT_METHOD
}

@main
struct NetworkPolicyStopTests {
    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    @MainActor
    private static func expectStopped(_ fixture: StopFixture, context: String) {
        let tunnel = fixture.tunnels[0]
        expect(!fixture.killSwitchArmedTunnelIDs.contains(tunnel.id),
            "\(context): a successful policy stop left the kill switch blocking traffic")
        expect(fixture.commandService.clearedRoutes == [tunnel.id], "\(context): exclusion routes were retained")
        expect(fixture.commandService.clearedSessions == [tunnel.id], "\(context): managed connected-user state was retained")
        expect(!tunnel.isActive && tunnel.connectedAt == nil && tunnel.runtimeConfigPath == nil
            && tunnel.interfaceName == nil && tunnel.lastHandshake == nil
            && tunnel.rxBytes == 0 && tunnel.txBytes == 0, "\(context): runtime state was retained")
        expect(fixture.trafficHistory.isEmpty && fixture.trafficSnapshots.isEmpty,
            "\(context): traffic samples were retained")
        expect(fixture.saved == 1 && fixture.warningUpdates == 1 && fixture.splitDNSUpdates == 1,
            "\(context): stopped state was not persisted and reconciled")
        expect(fixture.connectionFeedback.disconnectedIDs == [tunnel.id], "\(context): stop feedback was not finalized")
        expect(!fixture.networkMonitor.wasAutoConnected(tunnel.id), "\(context): automatic ownership was retained")
        expect(fixture.connectingTunnels.isEmpty && fixture.disconnectingTunnels.isEmpty && fixture.failures.isEmpty,
            "\(context): successful stop retained busy state or reported a failure")
        expect(fixture.commandService.stopped == ["/private/tmp/runtime.conf"]
            && fixture.commandService.started.isEmpty, "\(context): stop must use the runtime path without restarting")
    }

    @MainActor
    static func main() async {
        let lostNetwork = StopFixture()
        lostNetwork.commandService.onStop = { [weak lostNetwork] in
            lostNetwork?.networkMonitor.ssid = "Cafe"
        }
        await lostNetwork.restart()
        expectStopped(lostNetwork, context: "Leaving the connect network while helper stop is in progress")

        let disconnectNetwork = StopFixture()
        disconnectNetwork.networkMonitor.autoConnected = []
        disconnectNetwork.tunnels[0].autoConnectRule.disconnect = AutoConnectNetworkMatch(
            enabled: true, interface: .wifi, wifiSSIDs: ["Cafe"])
        disconnectNetwork.commandService.onStop = { [weak disconnectNetwork] in
            disconnectNetwork?.networkMonitor.ssid = "Cafe"
        }
        await disconnectNetwork.restart()
        expectStopped(disconnectNetwork, context: "Entering the disconnect network during a manually connected tunnel's restart")

        let ordinary = StopFixture()
        let stopped = await ordinary.disconnectTunnel(ordinary.tunnels[0])
        expect(stopped, "Ordinary disconnect failed")
        expectStopped(ordinary, context: "Ordinary disconnect")

        let permitted = StopFixture()
        await permitted.restart()
        expect(permitted.commandService.started == ["/private/tmp/runtime.conf"],
            "A still-matching tunnel must restart after renewal")
        expect(permitted.killSwitchArmedTunnelIDs.contains(permitted.tunnels[0].id)
            && permitted.commandService.clearedRoutes.isEmpty && permitted.commandService.clearedSessions.isEmpty,
            "A permitted restart must retain its protection, routes, and managed session")

        let pinned = StopFixture()
        pinned.tunnels[0].managedPolicy?.usersCanDisconnect = false
        pinned.commandService.onStop = { [weak pinned] in pinned?.networkMonitor.ssid = "Cafe" }
        await pinned.restart()
        expect(pinned.commandService.started == ["/private/tmp/runtime.conf"] && pinned.tunnels[0].isActive,
            "A managed tunnel users cannot disconnect must not be stopped by a network rule")

        let chained = StopFixture()
        chained.activeChain = TestChain(id: UUID())
        chained.commandService.onStop = { [weak chained] in chained?.networkMonitor.ssid = "Cafe" }
        await chained.restart()
        expect(chained.commandService.started == ["/private/tmp/runtime.conf"] && chained.tunnels[0].isActive,
            "A multi-hop chain leg must not be stopped by its own network rule")

        let inventory = StopFixture()
        inventory.tunnels[0].scope = .personal
        inventory.tunnels[0].managedPolicy = nil
        inventory.tunnels[0].inventoryCommand = InventoryCommand(executable: "/usr/bin/true", arguments: [])
        inventory.commandService.onStop = { [weak inventory] in inventory?.networkMonitor.ssid = "Cafe" }
        await inventory.restart()
        expect(inventory.protectedInventories == [inventory.tunnels[0].id] && !inventory.tunnels[0].isActive
            && inventory.commandService.started.isEmpty && inventory.failures.isEmpty,
            "A policy stop must keep inventory protection applied before the tunnel goes down")
        print("PASS: production policy-veto and ordinary stops finalize protection, managed sessions, and runtime state")
    }
}
