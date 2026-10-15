import Foundation

@MainActor
protocol TunnelShutdownClient: AnyObject {
    func beginShutdown()
    func cancelShutdown() async
    func waitForPendingOperations() async -> Bool
    func refreshForShutdown() async -> Bool
    func disconnectForShutdown() async -> Bool
    func restoreNetworkSettingsForShutdown() async -> Bool
    var hasActiveTunnels: Bool { get }
}

/// A normal Quit must not race connection setup or exit after failed cleanup.
@MainActor
final class TunnelShutdownCoordinator {
    private var pending: Task<Bool, Never>?
    private(set) var failureReason: String?

    func cancel(using client: TunnelShutdownClient) async {
        if let pending { _ = await pending.value }
        await client.cancelShutdown()
        failureReason = nil
    }

    func prepare(using client: TunnelShutdownClient) async -> Bool {
        if let pending { return await pending.value }
        failureReason = nil
        client.beginShutdown()
        let operation = Task { @MainActor in
            guard await client.waitForPendingOperations() else {
                self.failureReason = "A tunnel operation is still running. Wait for it to finish and retry."
                return false
            }
            guard await client.refreshForShutdown() else {
                self.failureReason = "Unable to confirm the current tunnel state."
                return false
            }
            guard await client.disconnectForShutdown() else {
                self.failureReason = "One or more tunnels could not be disconnected."
                return false
            }
            guard await client.refreshForShutdown(), !client.hasActiveTunnels else {
                self.failureReason = "A tunnel is still connected, or its disconnected state could not be confirmed."
                return false
            }
            guard await client.restoreNetworkSettingsForShutdown() else {
                self.failureReason = "Network settings could not be restored."
                return false
            }
            return true
        }
        pending = operation
        let ready = await operation.value
        pending = nil
        return ready
    }
}

/// An unavailable helper is harmless only when no runtime evidence exists.
enum TunnelShutdownRuntimeProbe {
    static func hasNoRuntimeEvidence(in directory: URL) -> Bool {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return !files.contains { ["sock", "name"].contains($0.pathExtension) }
        } catch CocoaError.fileReadNoSuchFile {
            return !FileManager.default.fileExists(atPath: directory.path)
        } catch {
            return false
        }
    }
}
