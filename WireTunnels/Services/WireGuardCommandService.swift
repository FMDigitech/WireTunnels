import Foundation
import Security
import ServiceManagement

struct KillSwitchEntry: Codable {
    let interfaceName: String
    let endpointHost: String
    let endpointPort: Int
}

@MainActor
final class WireGuardCommandService {
    nonisolated static let helperMachServiceName = "com.fmdigitech.WireTunnels.helper"
    nonisolated static let expectedHelperVersion = "1.0.3"
    nonisolated static let expectedHelperProtocolRevision = "kill-switch-v1"
    private static let helperCheckTimeoutNanoseconds: UInt64 = 3_000_000_000
    private static let keyGenerationTimeoutNanoseconds: UInt64 = 10_000_000_000
    private static let operationTimeoutNanoseconds: UInt64 = 30_000_000_000
    private static let toolInstallTimeoutNanoseconds: UInt64 = 60_000_000_000
    // Plist must be at Contents/Library/LaunchDaemons/ in the app bundle
    nonisolated static let helperPlistName = "com.fmdigitech.WireTunnels.helper.plist"

    private var connection: NSXPCConnection?
    // Kept alive across calls so the admin credential it caches is reused instead
    // of re-prompting for a password on every shared-tunnel operation. macOS ties
    // that cache to the specific AuthorizationRef, not just the login session.
    private var authorizationRef: AuthorizationRef?
    // ponytail: fresh instance per access, not stored — SMAppService.status can
    // go stale on a long-lived instance (macOS keeps toggling Login Items live,
    // reused SMAppService objects don't always pick it up without a relaunch).
    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: Self.helperPlistName)
    }

    func isHelperInstalled() -> Bool {
        daemonService.status == .enabled
    }

    var helperStatusDescription: String {
        switch daemonService.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(daemonService.status.rawValue))"
        }
    }

    struct HelperLaunchdDiagnostics {
        let summary: String
        /// launchd holds a registration it refuses to spawn (EX_CONFIG / spawn
        /// scheduled). Happens when the app bundle is replaced after the daemon
        /// was registered: the mach endpoint stays alive so XPC connects, but
        /// every call times out because the helper process never starts.
        let staleRegistration: Bool
    }

    nonisolated static let staleRegistrationRecoveryMessage = """
        The helper's launchd registration is stale (this happens after the app is updated or moved). \
        Quit WireTunnels, run in Terminal: sudo launchctl bootout system/\(helperMachServiceName) — \
        then reopen the app and use Re-detect. If it persists, toggle WireTunnels off and on in \
        System Settings > General > Login Items & Extensions, then restart the Mac.
        """

    /// Reads launchd's view of the helper daemon (works unprivileged).
    /// SMAppService.status only reflects the BTM disposition; this reveals
    /// whether launchd can actually spawn the helper.
    nonisolated static func launchdDiagnostics() -> HelperLaunchdDiagnostics {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(helperMachServiceName)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return HelperLaunchdDiagnostics(
                summary: "launchctl unavailable: \(error.localizedDescription)",
                staleRegistration: false
            )
        }
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            return HelperLaunchdDiagnostics(
                summary: "helper has no launchd registration (launchctl exit \(process.terminationStatus))",
                staleRegistration: false
            )
        }
        let markers = ["state =", "last exit code", "runs =", "path =", "program identifier"]
        let summary = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in markers.contains { line.contains($0) } }
            .joined(separator: "; ")
        let stale = output.contains("last exit code = 78")
            || output.contains("spawn scheduled")
        return HelperLaunchdDiagnostics(
            summary: summary.isEmpty ? "registered, no spawn detail available" : summary,
            staleRegistration: stale
        )
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
            if replacingExisting {
                // Stale BTM records can report any status — always attempt
                // unregister so register() creates a fresh record. Ignore
                // failures: a half-dead record often rejects unregister too.
                try? await unregisterHelper()
                invalidateConnection()
            }
            do {
                try daemonService.register()
            } catch {
                // register() right after unregister() reliably fails with
                // "Operation not permitted" — launchd needs a moment to drop
                // the old registration before it accepts a new one.
                guard replacingExisting else { throw error }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                try daemonService.register()
            }
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

    func helperProtocolRevision() async throws -> String {
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

            proxy.helperProtocolRevision { revision in
                Task { @MainActor in
                    timeoutTask.cancel()
                    resume(.success(revision))
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

    func syncKillSwitch(entries: [KillSwitchEntry]) async throws {
        let data = try JSONEncoder().encode(entries)
        return try await performHelperOperation(timeoutDescription: "Updating kill switch") { helper, complete in
            helper.syncKillSwitch(entries: data) { success, errorMessage in
                complete(success
                    ? .success(())
                    : .failure(CommandError.killSwitchFailed(errorMessage ?? "Unknown")))
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

    func listManagedTunnels() async throws -> [Tunnel] {
        let data: Data = try await performHelperOperation(timeoutDescription: "Loading managed tunnels") { helper, complete in
            helper.listManagedTunnels { data, errorMessage in
                if let data {
                    complete(.success(data))
                } else {
                    complete(.failure(CommandError.managedTunnelFailed(errorMessage ?? "Unknown")))
                }
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Tunnel].self, from: data)
    }

    func installManagedTunnel(name: String, contents: Data) async throws {
        let authorization = try adminAuthorizationToken()
        try await performHelperOperation(timeoutDescription: "Installing managed tunnel") { helper, complete in
            helper.installManagedTunnel(named: name, contents: contents, authorization: authorization) { success, errorMessage in
                complete(success
                    ? .success(())
                    : .failure(CommandError.managedTunnelFailed(errorMessage ?? "Unknown")))
            }
        }
    }

    func updateManagedTunnel(
        id: UUID,
        name: String,
        contents: Data?,
        policy: ManagedTunnelPolicy,
        autoConnectRule: AutoConnectRule
    ) async throws {
        let encoder = JSONEncoder()
        let policyData = try encoder.encode(policy)
        let ruleData = try encoder.encode(autoConnectRule)
        let authorization = try adminAuthorizationToken()
        try await performHelperOperation(timeoutDescription: "Updating managed tunnel") { helper, complete in
            helper.updateManagedTunnel(
                id: id.uuidString,
                name: name,
                contents: contents,
                policy: policyData,
                autoConnectRule: ruleData,
                authorization: authorization
            ) { success, errorMessage in
                complete(success
                    ? .success(())
                    : .failure(CommandError.managedTunnelFailed(errorMessage ?? "Unknown")))
            }
        }
    }

    func deleteManagedTunnel(id: UUID) async throws {
        let authorization = try adminAuthorizationToken()
        try await performHelperOperation(timeoutDescription: "Deleting managed tunnel") { helper, complete in
            helper.deleteManagedTunnel(id: id.uuidString, authorization: authorization) { success, errorMessage in
                complete(success
                    ? .success(())
                    : .failure(CommandError.managedTunnelFailed(errorMessage ?? "Unknown")))
            }
        }
    }

    func stageManagedConfig(id: UUID) async throws -> String {
        try await performHelperOperation(timeoutDescription: "Staging managed tunnel configuration") { helper, complete in
            helper.stageManagedConfig(id: id.uuidString) { path, errorMessage in
                if let path {
                    complete(.success(path))
                } else {
                    complete(.failure(CommandError.copyFailed(errorMessage ?? "Unknown")))
                }
            }
        }
    }

    func markManagedTunnelConnected(id: UUID) async throws {
        try await performHelperOperation(timeoutDescription: "Recording managed tunnel user") { helper, complete in
            helper.markManagedTunnelConnected(id: id.uuidString) { success, errorMessage in
                complete(success
                    ? .success(())
                    : .failure(CommandError.managedTunnelFailed(errorMessage ?? "Unknown")))
            }
        }
    }

    func markManagedTunnelDisconnected(id: UUID) async throws {
        try await performHelperOperation(timeoutDescription: "Clearing managed tunnel user") { helper, complete in
            helper.markManagedTunnelDisconnected(id: id.uuidString) { success, errorMessage in
                complete(success
                    ? .success(())
                    : .failure(CommandError.managedTunnelFailed(errorMessage ?? "Unknown")))
            }
        }
    }

    func listManagedTunnelUsers(id: UUID) async throws -> [ManagedTunnelUserSession] {
        let authorization = try adminAuthorizationToken()
        let data: Data = try await performHelperOperation(timeoutDescription: "Loading managed tunnel users") { helper, complete in
            helper.listManagedTunnelUsers(id: id.uuidString, authorization: authorization) { data, errorMessage in
                if let data {
                    complete(.success(data))
                } else {
                    complete(.failure(CommandError.managedTunnelFailed(errorMessage ?? "Unknown")))
                }
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ManagedTunnelUserSession].self, from: data)
    }

    private func adminAuthorizationToken() throws -> Data {
        let authRef = try acquireAuthorizationRef()

        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let copyStatus = "system.privilege.admin".withCString { rightName in
            var item = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(authRef, &rights, nil, flags, nil)
            }
        }
        guard copyStatus == errAuthorizationSuccess else {
            throw CommandError.authorizationFailed(copyStatus)
        }

        var externalForm = AuthorizationExternalForm()
        let externalStatus = AuthorizationMakeExternalForm(authRef, &externalForm)
        guard externalStatus == errAuthorizationSuccess else {
            throw CommandError.authorizationFailed(externalStatus)
        }
        return withUnsafeBytes(of: &externalForm) { Data($0) }
    }

    private func acquireAuthorizationRef() throws -> AuthorizationRef {
        if let authorizationRef {
            return authorizationRef
        }
        var authRef: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, AuthorizationFlags(), &authRef)
        guard createStatus == errAuthorizationSuccess, let authRef else {
            throw CommandError.authorizationFailed(createStatus)
        }
        authorizationRef = authRef
        return authRef
    }

    func invalidateConnection() {
        connection?.invalidate()
        connection = nil
    }

    deinit {
        if let authorizationRef {
            AuthorizationFree(authorizationRef, [])
        }
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
    case authorizationFailed(OSStatus)
    case managedTunnelFailed(String)
    case killSwitchFailed(String)

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
        case .authorizationFailed(let status): return "Administrator authorization failed (\(status))"
        case .managedTunnelFailed(let msg): return "Managed tunnel operation failed: \(msg)"
        case .killSwitchFailed(let msg): return "Kill switch update failed: \(msg)"
        }
    }
}
