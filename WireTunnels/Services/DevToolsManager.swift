import Combine
import Foundation

struct DevToolsData: Codable, Equatable {
    var wakeTargets: [WakeTarget] = []
    var sshTunnels: [SSHTunnel] = []
}

enum SSHTunnelState: Equatable {
    case stopped
    case connecting
    case running
    /// ssh exited and will be restarted at `retryAt`.
    case waiting(retryAt: Date, reason: String)
    case failed(String)
}

/// Wake-on-LAN targets and SSH port forwards kept alive by the app. Everything runs as the current
/// user: ssh uses the user's own keys and agent, never a password, and nothing here is privileged.
@MainActor
final class DevToolsManager: ObservableObject {
    @Published private(set) var data = DevToolsData()
    @Published private(set) var states: [UUID: SSHTunnelState] = [:]
    @Published var errorMessage: String?
    @Published private(set) var lastWake: (id: UUID, succeeded: Bool)?

    private let store: RecoverableJSONStore<DevToolsData>
    private let log: LogService
    private var processes: [UUID: Process] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var attempts: [UUID: Int] = [:]
    private var startedAt: [UUID: Date] = [:]
    /// Tunnels the user asked to keep running; only these are restarted.
    private var wanted: Set<UUID> = []

    init(file: URL = AppPaths.userMetadataDir.appendingPathComponent("devTools.json"), log: LogService? = nil) {
        store = RecoverableJSONStore(file: file, emptyValue: DevToolsData())
        self.log = log ?? .shared
    }

    func load() {
        do {
            data = try store.load()
            if let warning = store.recoveryWarning { log.warning(warning) }
        } catch {
            errorMessage = "Developer tools could not be read: \(error.localizedDescription)"
        }
    }

    private func persist(_ updated: DevToolsData) -> Bool {
        do {
            try store.save(updated)
            data = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Developer tools could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Wake-on-LAN

    func saveWakeTarget(_ target: WakeTarget) {
        var updated = data
        if let index = updated.wakeTargets.firstIndex(where: { $0.id == target.id }) {
            updated.wakeTargets[index] = target
        } else {
            updated.wakeTargets.append(target)
        }
        _ = persist(updated)
    }

    func deleteWakeTarget(_ id: UUID) {
        var updated = data
        updated.wakeTargets.removeAll { $0.id == id }
        _ = persist(updated)
    }

    func wake(_ target: WakeTarget) {
        let succeeded = MagicPacket.send(to: target)
        lastWake = (target.id, succeeded)
        if succeeded {
            log.info("Sent a Wake-on-LAN packet to \(target.name)")
        } else {
            log.warning("Could not send a Wake-on-LAN packet to \(target.name)")
        }
    }

    // MARK: SSH tunnels

    func saveSSHTunnel(_ tunnel: SSHTunnel) {
        var updated = data
        if let index = updated.sshTunnels.firstIndex(where: { $0.id == tunnel.id }) {
            updated.sshTunnels[index] = tunnel
        } else {
            updated.sshTunnels.append(tunnel)
        }
        let wasRunning = wanted.contains(tunnel.id)
        guard persist(updated) else { return }
        // The forwards may have changed: restart so the running ssh matches what is saved.
        if wasRunning { stopSSH(tunnel.id); startSSH(tunnel.id) }
    }

    func deleteSSHTunnel(_ id: UUID) {
        stopSSH(id)
        states[id] = nil
        var updated = data
        updated.sshTunnels.removeAll { $0.id == id }
        _ = persist(updated)
    }

    func state(of id: UUID) -> SSHTunnelState { states[id] ?? .stopped }

    func startSSH(_ id: UUID) {
        guard let tunnel = data.sshTunnels.first(where: { $0.id == id }) else { return }
        wanted.insert(id)
        attempts[id] = 0
        launch(tunnel)
    }

    func stopSSH(_ id: UUID) {
        wanted.remove(id)
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        if let process = processes.removeValue(forKey: id), process.isRunning { process.terminate() }
        if states[id] != nil { states[id] = .stopped }
    }

    func stopAll() {
        for id in Array(wanted) { stopSSH(id) }
    }

    private func launch(_ tunnel: SSHTunnel) {
        guard processes[tunnel.id] == nil else { return }
        guard let arguments = SSHTunnelCommand.arguments(for: tunnel) else {
            wanted.remove(tunnel.id)
            states[tunnel.id] = .failed(SSHTunnelCommand.problem(with: tunnel) ?? "The tunnel is not valid.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let id = tunnel.id
        let collected = ErrorBuffer()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { collected.append(chunk) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let message = collected.text
            Task { @MainActor in self?.didExit(id: id, process: finished, status: status, message: message) }
        }
        do {
            try process.run()
        } catch {
            states[id] = .failed("ssh could not start: \(error.localizedDescription)")
            wanted.remove(id)
            return
        }
        processes[id] = process
        startedAt[id] = Date()
        states[id] = .connecting
        log.info("SSH tunnel \(tunnel.name) started")
        // ExitOnForwardFailure makes ssh exit within moments if a port is busy or auth fails; a process
        // that is still alive after the connect timeout is carrying traffic.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.processes[id] === process, process.isRunning else { return }
            self.states[id] = .running
        }
    }

    private func didExit(id: UUID, process: Process, status: Int32, message: String) {
        // A restart may already have replaced this process.
        guard processes[id] === process else { return }
        processes[id] = nil
        let name = data.sshTunnels.first { $0.id == id }?.name ?? "SSH tunnel"
        let reason = message.isEmpty ? "ssh exited with status \(status)" : String(message.suffix(200))
        guard wanted.contains(id), let tunnel = data.sshTunnels.first(where: { $0.id == id }) else {
            states[id] = .stopped
            return
        }
        guard tunnel.reconnects else {
            wanted.remove(id)
            states[id] = .failed(reason)
            log.warning("SSH tunnel \(name) ended: \(reason)")
            return
        }
        if let started = startedAt[id], Date().timeIntervalSince(started) >= SSHTunnelCommand.stableRunDuration { attempts[id] = 0 }
        let attempt = attempts[id] ?? 0
        attempts[id] = attempt + 1
        let delay = SSHTunnelCommand.reconnectDelay(attempt: attempt)
        states[id] = .waiting(retryAt: Date().addingTimeInterval(delay), reason: reason)
        log.warning("SSH tunnel \(name) ended (\(reason)); retrying in \(Int(delay)) s")
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.wanted.contains(id),
                  let current = self.data.sshTunnels.first(where: { $0.id == id }) else { return }
            self.retryTasks[id] = nil
            self.launch(current)
        }
    }
}

private final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > 4096 { data = data.suffix(4096) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
