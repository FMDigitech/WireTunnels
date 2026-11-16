import Combine
import Foundation

/// Runs a mesh VPN's command line as the current user. Nothing here is privileged: if the client
/// refuses an action for this user, the refusal is shown as it is.
nonisolated enum MeshVPNRunner {
    private final class Output: @unchecked Sendable {
        var data = Data()
    }

    struct Result {
        let exitStatus: Int32
        let output: Data
    }

    /// The first install of the client that exists and can be run.
    static func executable(for kind: MeshVPNKind) -> String? {
        kind.candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Blocking. Output is read while the tool runs so a long status cannot fill the pipe, and a
    /// tool that does not finish in `timeout` seconds is stopped and reported as nil.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let output = Output()
        let reader = DispatchGroup()
        do { try process.run() } catch { return nil }
        reader.enter()
        DispatchQueue.global().async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            reader.wait()
            return nil
        }
        reader.wait()
        return Result(exitStatus: process.terminationStatus, output: output.data)
    }

    static func readStatus(_ kind: MeshVPNKind) -> Outcome {
        guard let path = executable(for: kind) else { return .notInstalled }
        guard let result = run(path, kind.statusArguments, timeout: 8) else {
            return .failed("\(kind.displayName) did not answer in time.")
        }
        // A client that is installed but not running exits non-zero with a message, not JSON.
        if let status = MeshVPNParser.parse(result.output, kind: kind) { return .status(status) }
        let text = String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failed(text.isEmpty ? "\(kind.displayName) is installed but not running." : String(text.prefix(300)))
    }

    enum Outcome: Equatable {
        case notInstalled
        case status(MeshVPNStatus)
        case failed(String)
    }
}

@MainActor
final class MeshVPNManager: ObservableObject {
    @Published private(set) var outcomes: [MeshVPNKind: MeshVPNRunner.Outcome] = [:]
    @Published private(set) var busy: Set<MeshVPNKind> = []
    @Published private(set) var actionErrors: [MeshVPNKind: String] = [:]
    @Published private(set) var hasLoaded = false

    func refresh() async {
        let result = await Task.detached {
            Dictionary(uniqueKeysWithValues: MeshVPNKind.allCases.map { ($0, MeshVPNRunner.readStatus($0)) })
        }.value
        if outcomes != result { outcomes = result }
        hasLoaded = true
    }

    /// Runs one command for a client and reads its status again, so the screen shows what happened
    /// and not what was asked for.
    private func perform(_ kind: MeshVPNKind, _ arguments: [String], timeout: TimeInterval = 20) async {
        guard !busy.contains(kind), let path = MeshVPNRunner.executable(for: kind) else { return }
        busy.insert(kind)
        actionErrors[kind] = nil
        let result = await Task.detached { MeshVPNRunner.run(path, arguments, timeout: timeout) }.value
        if result == nil {
            actionErrors[kind] = "\(kind.displayName) did not finish in time."
        } else if let result, result.exitStatus != 0 {
            let text = String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            actionErrors[kind] = text.isEmpty ? "\(kind.displayName) refused the request." : String(text.prefix(300))
        }
        busy.remove(kind)
        await refresh()
    }

    func setEnabled(_ kind: MeshVPNKind, _ enabled: Bool) async {
        // Only a client that reports on or off is driven. A login or approval is done in its own app,
        // and `up` would sit waiting for it.
        guard case .status(let status)? = outcomes[kind], status.state.canToggle else { return }
        await perform(kind, enabled ? kind.upArguments : kind.downArguments)
    }

    func setExitNode(_ node: MeshExitNode?) async {
        guard let arguments = MeshVPNCommand.setExitNode(node?.id) else { return }
        await perform(.tailscale, arguments)
    }
}
