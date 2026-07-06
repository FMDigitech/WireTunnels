import Foundation
import ServiceManagement

@MainActor
final class WireGuardCommandService {
    static let helperMachServiceName = "com.fmdigitech.WireTunnels.helper"
    static let expectedHelperVersion = "1.0"
    private static let helperCheckTimeoutNanoseconds: UInt64 = 3_000_000_000
    private static let keyGenerationTimeoutNanoseconds: UInt64 = 10_000_000_000
    private static let operationTimeoutNanoseconds: UInt64 = 30_000_000_000
    private static let toolInstallTimeoutNanoseconds: UInt64 = 60_000_000_000
    // Plist must be at Contents/Library/LaunchDaemons/ in the app bundle
    static let helperPlistName = "com.fmdigitech.WireTunnels.helper.plist"

    private var connection: NSXPCConnection?
    private let daemonService = SMAppService.daemon(plistName: "com.fmdigitech.WireTunnels.helper.plist")

    func isHelperInstalled() -> Bool {
        daemonService.status == .enabled
    }

    func helperRequiresApproval() -> Bool {
        daemonService.status == .requiresApproval
    }

    func openHelperApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func installHelper(replacingExisting: Bool = false) async throws {
        do {
            guard isInstalledApplicationBundle else {
                throw CommandError.helperReplacementRequiresInstalledApp
            }
            if replacingExisting && daemonService.status == .enabled {
                try await unregisterHelper()
                invalidateConnection()
            }
            try daemonService.register()
            if daemonService.status == .requiresApproval {
                throw CommandError.helperApprovalRequired
            }
        } catch CommandError.helperApprovalRequired {
            throw CommandError.helperApprovalRequired
        } catch {
            if daemonService.status == .requiresApproval {
                throw CommandError.helperApprovalRequired
            }
            throw CommandError.helperInstallFailed(error.localizedDescription)
        }
    }

    private var isInstalledApplicationBundle: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }

    private func unregisterHelper() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            daemonService.unregister { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func getHelper() throws -> WireguardHelperProtocol {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: Self.helperMachServiceName, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: WireguardHelperProtocol.self)
            conn.resume()
            connection = conn
        }
        guard let helper = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { @MainActor in
                self?.connection = nil
            }
        }) as? WireguardHelperProtocol else {
            throw CommandError.connectionFailed
        }
        return helper
    }

    private func performHelperOperation<T>(
        timeoutDescription: String,
        invoke: @escaping (
            WireguardHelperProtocol,
            @escaping (Result<T, Error>) -> Void
        ) -> Void
    ) async throws -> T {
        _ = try getHelper()
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let resume: (Result<T, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.operationTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                self?.invalidateConnection()
                resume(.failure(CommandError.operationTimedOut(timeoutDescription)))
            }

            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
                Task { @MainActor in
                    timeoutTask.cancel()
                    self?.connection = nil
                    resume(.failure(CommandError.connectionInterrupted(error.localizedDescription)))
                }
            }) as? WireguardHelperProtocol else {
                timeoutTask.cancel()
                resume(.failure(CommandError.connectionFailed))
                return
            }

            invoke(proxy) { result in
                Task { @MainActor in
                    timeoutTask.cancel()
                    resume(result)
                }
            }
        }
    }

    func helperVersion() async throws -> String {
        _ = try getHelper()
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let resume: (Result<String, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.helperCheckTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                self?.invalidateConnection()
                resume(.failure(CommandError.helperCheckTimedOut))
            }

            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
                Task { @MainActor in
                    timeoutTask.cancel()
                    self?.connection = nil
                    resume(.failure(CommandError.connectionInterrupted(error.localizedDescription)))
                }
            }) as? WireguardHelperProtocol else {
                timeoutTask.cancel()
                resume(.failure(CommandError.connectionFailed))
                return
            }

            proxy.helperVersion { version in
                Task { @MainActor in
                    timeoutTask.cancel()
                    resume(.success(version))
                }
            }
        }
    }

    func installBundledTools() async throws {
        _ = try getHelper()
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let resume: (Result<Void, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.toolInstallTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                self?.invalidateConnection()
                resume(.failure(CommandError.operationTimedOut("Installing WireGuard tools")))
            }

            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
                Task { @MainActor in
                    timeoutTask.cancel()
                    self?.connection = nil
                    resume(.failure(CommandError.connectionInterrupted(error.localizedDescription)))
                }
            }) as? WireguardHelperProtocol else {
                timeoutTask.cancel()
                resume(.failure(CommandError.connectionFailed))
                return
            }

            proxy.installBundledTools { success, errorMessage in
                Task { @MainActor in
                    timeoutTask.cancel()
                    if success {
                        resume(.success(()))
                    } else {
                        resume(.failure(CommandError.installFailed(errorMessage ?? "Unknown")))
                    }
                }
            }
        }
    }

    func startTunnel(configPath: String) async throws {
        let name = URL(fileURLWithPath: configPath).lastPathComponent
        return try await performHelperOperation(timeoutDescription: "Starting tunnel") { helper, complete in
            helper.startTunnel(named: name) { success, errorMessage in
                complete(success
                    ? .success(())
                    : .failure(CommandError.tunnelStartFailed(errorMessage ?? "Unknown")))
            }
        }
    }

    func stopTunnel(configPath: String) async throws {
        let name = URL(fileURLWithPath: configPath).lastPathComponent
        return try await performHelperOperation(timeoutDescription: "Stopping tunnel") { helper, complete in
            helper.stopTunnel(named: name) { success, errorMessage in
                complete(success
                    ? .success(())
                    : .failure(CommandError.tunnelStopFailed(errorMessage ?? "Unknown")))
            }
        }
    }

    func getWgShowOutput() async throws -> String {
        try await performHelperOperation(timeoutDescription: "Refreshing tunnel status") { helper, complete in
            helper.runWgShow { output, errorMessage in
                if let output = output {
                    complete(.success(output))
                } else {
                    complete(.failure(CommandError.statusFailed(errorMessage ?? "Unknown")))
                }
            }
        }
    }

    func generateKeyPair() async throws -> (privateKey: String, publicKey: String) {
        _ = try getHelper()
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let resume: (Result<(privateKey: String, publicKey: String), Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.keyGenerationTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                self?.invalidateConnection()
                resume(.failure(CommandError.keyGenerationFailed("Request timed out")))
            }

            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
                Task { @MainActor in
                    timeoutTask.cancel()
                    self?.connection = nil
                    resume(.failure(CommandError.connectionInterrupted(error.localizedDescription)))
                }
            }) as? WireguardHelperProtocol else {
                timeoutTask.cancel()
                resume(.failure(CommandError.connectionFailed))
                return
            }

            proxy.generateKeyPair { privateKey, publicKey, errorMessage in
                Task { @MainActor in
                    timeoutTask.cancel()
                    if let privateKey, let publicKey {
                        resume(.success((privateKey, publicKey)))
                    } else {
                        resume(.failure(
                            CommandError.keyGenerationFailed(errorMessage ?? "Unknown")
                        ))
                    }
                }
            }
        }
    }

    func copyConfig(from sourcePath: String, to destPath: String) async throws {
        let name = URL(fileURLWithPath: destPath).lastPathComponent
        let contents: Data
        do {
            contents = try Data(contentsOf: URL(fileURLWithPath: sourcePath), options: .mappedIfSafe)
        } catch {
            throw CommandError.copyFailed(error.localizedDescription)
        }
        return try await performHelperOperation(timeoutDescription: "Staging tunnel configuration") { helper, complete in
            helper.stageConfig(named: name, contents: contents) { success, errorMessage in
                complete(success
                    ? .success(())
                    : .failure(CommandError.copyFailed(errorMessage ?? "Unknown")))
            }
        }
    }

    func invalidateConnection() {
        connection?.invalidate()
        connection = nil
    }
}

enum CommandError: LocalizedError {
    case helperInstallFailed(String)
    case helperApprovalRequired
    case helperReplacementRequiresInstalledApp
    case connectionFailed
    case connectionInterrupted(String)
    case operationTimedOut(String)
    case helperCheckTimedOut
    case bundleNotFound
    case installFailed(String)
    case tunnelStartFailed(String)
    case tunnelStopFailed(String)
    case statusFailed(String)
    case keyGenerationFailed(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperInstallFailed(let msg): return "Helper install failed: \(msg)"
        case .helperApprovalRequired:
            return "The privileged helper must be enabled in System Settings > General > Login Items & Extensions"
        case .helperReplacementRequiresInstalledApp:
            return "Move WireTunnels to /Applications and launch it from there before installing or updating the privileged helper."
        case .connectionFailed: return "Cannot connect to privileged helper"
        case .connectionInterrupted(let msg): return "Privileged helper connection failed: \(msg)"
        case .operationTimedOut(let operation):
            return "\(operation) timed out because the privileged helper did not respond."
        case .helperCheckTimedOut: return "Privileged helper did not respond within 3 seconds"
        case .bundleNotFound: return "App bundle path not found"
        case .installFailed(let msg): return "Binary install failed: \(msg)"
        case .tunnelStartFailed(let msg): return "Failed to start tunnel: \(msg)"
        case .tunnelStopFailed(let msg): return "Failed to stop tunnel: \(msg)"
        case .statusFailed(let msg): return "Failed to get status: \(msg)"
        case .keyGenerationFailed(let msg): return "Failed to generate WireGuard keys: \(msg)"
        case .copyFailed(let msg): return "Failed to copy config: \(msg)"
        }
    }
}
