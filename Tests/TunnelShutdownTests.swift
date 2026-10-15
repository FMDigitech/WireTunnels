import Foundation

@MainActor
private final class ShutdownFixture: TunnelShutdownClient {
    var hasActiveTunnels = true
    var connectionsBlocked = false
    var waiting: CheckedContinuation<Bool, Never>?
    var holdSetup = false
    var canReadStatus = true
    var canDisconnect = true
    var canRestore = true
    var leavesTunnelActive = false
    var cleanups = 0
    var policyStillApplied = true
    var automationResumed = false

    func beginShutdown() { connectionsBlocked = true; automationResumed = false }
    func cancelShutdown() async {
        // Partial teardown left rules for disconnected tunnels installed.
        policyStillApplied = hasActiveTunnels
        connectionsBlocked = false
        automationResumed = true
    }
    func waitForPendingOperations() async -> Bool {
        guard connectionsBlocked else { fatalError("Shutdown waited before blocking new connections") }
        if holdSetup {
            return await withCheckedContinuation { waiting = $0 }
        }
        return true
    }
    func refreshForShutdown() async -> Bool { canReadStatus }
    func disconnectForShutdown() async -> Bool {
        guard waiting == nil else { fatalError("Shutdown raced an unfinished connection") }
        cleanups += 1
        if canDisconnect { hasActiveTunnels = leavesTunnelActive }
        return canDisconnect
    }
    func restoreNetworkSettingsForShutdown() async -> Bool { canRestore }
}

@main
struct TunnelShutdownTests {
    @MainActor
    private static func waitForSetup(_ fixture: ShutdownFixture) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while fixture.waiting == nil {
            guard ProcessInfo.processInfo.systemUptime < deadline else { fatalError("Quit did not wait for pending setup") }
            await Task.yield()
        }
    }

    @MainActor
    static func main() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard TunnelShutdownRuntimeProbe.hasNoRuntimeEvidence(in: directory) else { fatalError("Fresh install could not quit") }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard TunnelShutdownRuntimeProbe.hasNoRuntimeEvidence(in: directory) else { fatalError("Empty runtime directory blocked quit") }
            let alias = directory.appendingPathComponent("shared.name")
            try Data("utun7\n".utf8).write(to: alias)
            guard !TunnelShutdownRuntimeProbe.hasNoRuntimeEvidence(in: directory) else { fatalError("Unavailable helper hid a shared tunnel alias") }
            try FileManager.default.removeItem(at: alias)
            try Data().write(to: directory.appendingPathComponent("utun7.sock"))
            guard !TunnelShutdownRuntimeProbe.hasNoRuntimeEvidence(in: directory) else { fatalError("Unavailable helper hid a runtime socket") }
            let unreadable = directory.appendingPathComponent("not-a-directory")
            try Data().write(to: unreadable)
            guard !TunnelShutdownRuntimeProbe.hasNoRuntimeEvidence(in: unreadable) else { fatalError("Runtime inspection failure allowed quit") }
        } catch { fatalError("Runtime fixture failed: \(error)") }

        let coordinator = TunnelShutdownCoordinator()
        let client = ShutdownFixture()
        client.holdSetup = true
        let first = Task { await coordinator.prepare(using: client) }
        await waitForSetup(client)
        guard client.connectionsBlocked, client.cleanups == 0 else { fatalError("Quit failed to wait for pending setup") }
        let second = Task { await coordinator.prepare(using: client) }
        await Task.yield()
        let waiting = client.waiting
        client.waiting = nil
        waiting?.resume(returning: true)
        guard await first.value, await second.value, client.cleanups == 1, !client.hasActiveTunnels else {
            fatalError("Repeated Quit requests raced or exited with a connected tunnel")
        }
        for failure in ["status", "disconnect", "active", "network", "pending"] {
            let fixture = ShutdownFixture()
            fixture.canReadStatus = failure != "status"
            fixture.canDisconnect = failure != "disconnect"
            fixture.leavesTunnelActive = failure == "active"
            fixture.canRestore = failure != "network"
            if failure == "pending" {
                fixture.holdSetup = true
                let attempt = Task { await coordinator.prepare(using: fixture) }
                await waitForSetup(fixture)
                let waiting = fixture.waiting
                fixture.waiting = nil
                waiting?.resume(returning: false)
                guard await !attempt.value, coordinator.failureReason != nil else { fatalError("Quit ignored pending setup failure") }
            } else {
                guard await !coordinator.prepare(using: fixture), coordinator.failureReason != nil else {
                    fatalError("Quit ignored \(failure) failure")
                }
            }
        }
        let inactive = ShutdownFixture()
        inactive.hasActiveTunnels = false
        inactive.canReadStatus = false
        guard await !coordinator.prepare(using: inactive) else {
            fatalError("Quit trusted stale inactive state without checking runtime status")
        }
        let canceled = ShutdownFixture()
        canceled.canRestore = false
        guard await !coordinator.prepare(using: canceled), !canceled.hasActiveTunnels,
              canceled.policyStillApplied, canceled.connectionsBlocked else {
            fatalError("Partial shutdown cancellation fixture did not retain stale policy")
        }
        await coordinator.cancel(using: canceled)
        guard !canceled.policyStillApplied, !canceled.connectionsBlocked,
              canceled.automationResumed, coordinator.failureReason == nil else {
            fatalError("Cancel Quit resumed with stale network policy or a stale quit failure")
        }
        canceled.canRestore = true
        guard await coordinator.prepare(using: canceled) else { fatalError("Quit after cancellation failed") }
        let retry = ShutdownFixture()
        retry.canDisconnect = false
        guard await !coordinator.prepare(using: retry) else { fatalError("Failed cleanup allowed quit") }
        retry.canDisconnect = true
        guard await coordinator.prepare(using: retry), coordinator.failureReason == nil else { fatalError("Successful retry did not allow quit") }
        print("PASS: quit waits for setup, blocks new connections, coalesces requests, and refuses exit after cleanup failure")
    }
}
