import Foundation
import Combine
import AppKit
import ServiceManagement

@MainActor
final class TunnelManager: ObservableObject {
    @Published var tunnels: [Tunnel] = []
    @Published var environment: WireGuardEnvironment = WireGuardEnvironment()
    @Published var isLoading: Bool = false
    @Published var setupStatus: String? = nil
    @Published var errorMessage: String? = nil
    @Published var helperRequiresApproval: Bool = false
    @Published var bundledRuntimeStatus: WireGuardRuntimeStatus?
    @Published var toolInstallRequired: Bool = false
    @Published var activeWarnings: [TunnelWarning] = []
    @Published var isDashboardOpen: Bool = false
    @Published var isInitialized: Bool = false
    @Published var trafficHistory: [UUID: [TrafficSample]] = [:]
    let currentUserIsAdministrator = TunnelManager.currentUserIsAdministrator()

    private var trafficSnapshots: [UUID: (rx: Int64, tx: Int64, time: Date)] = [:]
    private let maxTrafficSamples = 20

    let commandService = WireGuardCommandService()
    let networkMonitor = NetworkMonitorService()
    private let repository = TunnelRepository()
    private let configStorage = ConfigStorageService()
    private let parser = WireGuardConfigParser()
    private let toolLocator = WireGuardToolLocator()
    private let log = LogService.shared
    private let notificationService = NotificationService.shared
    private let resetService = AppDataResetService.shared
    private lazy var statusMonitor = StatusMonitorService(commandService: commandService)
    private var pollingTask: Task<Void, Never>?
    private var networkCancellable: AnyCancellable?
    private var networkChangeDebounceTask: Task<Void, Never>?
    private var connectingTunnels: Set<UUID> = []
    private var statusFailureReported = false

    // MARK: - Initialization

    init() {
        // Relay networkMonitor changes so views observing TunnelManager redraw on network state changes
        networkCancellable = networkMonitor.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
        networkMonitor.onNetworkChange = { [weak self] in
            // Debounce: NWPathMonitor fires multiple times per real network change
            // (e.g. wireguard-go creating a utun triggers another path update).
            // Wait 500 ms before acting so only the final stable state matters.
            self?.networkChangeDebounceTask?.cancel()
            self?.networkChangeDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await self?.handleNetworkChange()
            }
        }
        Task { await initialize() }
    }

    func initialize() async {
        isLoading = true
        setupStatus = nil
        defer {
            isLoading = false
            setupStatus = nil
            isInitialized = true
        }

        log.info("App initializing")

        // Load persisted personal tunnels first
        tunnels = repository.load().filter { $0.scope == .personal }
        log.info("Loaded \(tunnels.count) tunnels from storage")

        // Backfill publicKey / address for tunnels saved before these fields were populated
        var needsSave = false
        for index in tunnels.indices where tunnels[index].publicKey == nil || tunnels[index].address == nil {
            if let parsed = try? parser.parse(contentsOf: URL(fileURLWithPath: tunnels[index].configPath)) {
                if tunnels[index].publicKey == nil, let key = parsed.peerPublicKey {
                    tunnels[index].publicKey = key
                    needsSave = true
                }
                if tunnels[index].address == nil {
                    tunnels[index].address = parsed.address
                    needsSave = true
                }
            }
        }
        if needsSave { savePersonalTunnelsOnly() }

        // Detect environment
        setupStatus = "Detecting environment…"
        errorMessage = nil
        bundledRuntimeStatus = toolLocator.inspectBundledRuntime()
        environment = toolLocator.detect()
        let helperStatus = await effectiveHelperStatus()
        environment.helperInstalled = helperStatus.installed
        helperRequiresApproval = helperStatus.requiresApproval

        if helperRequiresApproval {
            let message = "Enable the privileged helper in System Settings, then run Re-detect."
            log.error(message)
            errorMessage = message
            return
        }

        var shouldReplaceHelper = false
        if environment.helperInstalled {
            setupStatus = "Checking privileged helper…"
            do {
                let version: String
                if let knownVersion = helperStatus.version {
                    version = knownVersion
                } else {
                    version = try await commandService.helperVersion()
                }
                log.info("Privileged helper reachable (version \(version))")
                if await helperNeedsReplacement(version: version) {
                    shouldReplaceHelper = true
                    log.warning(
                        "Privileged helper version/protocol is stale; version \(version), expected \(WireGuardCommandService.expectedHelperVersion)"
                    )
                }
            } catch {
                // Daemon may still be starting — wait 2s and retry once before replacing
                log.info("Helper check failed, retrying in 2s… (\(error.localizedDescription))")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    let version = try await commandService.helperVersion()
                    log.info("Privileged helper reachable after retry (version \(version))")
                    if await helperNeedsReplacement(version: version) {
                        shouldReplaceHelper = true
                        log.warning(
                            "Privileged helper version/protocol is stale; version \(version), expected \(WireGuardCommandService.expectedHelperVersion)"
                        )
                    }
                } catch {
                    shouldReplaceHelper = true
                    log.error("Registered helper is unreachable: \(error.localizedDescription)")
                    logHelperLaunchdDiagnostics()
                }
            }
        }

        // Install helper if needed, replacing stale registrations that cannot launch.
        if !environment.helperInstalled || shouldReplaceHelper {
            setupStatus = "Installing privileged helper (system prompt may appear)…"
            do {
                log.info(shouldReplaceHelper
                         ? "Replacing stale privileged helper"
                         : "Installing privileged helper")
                try await commandService.installHelper(replacingExisting: shouldReplaceHelper)
                environment.helperInstalled = true
                helperRequiresApproval = false
                log.info("Helper installed successfully")
            } catch {
                helperRequiresApproval = commandService.helperRequiresApproval()
                log.error("Helper installation failed: \(error.localizedDescription)")
                let stale = logHelperLaunchdDiagnostics()
                errorMessage = stale
                    ? WireGuardCommandService.staleRegistrationRecoveryMessage
                    : error.localizedDescription
                return
            }
        }

        toolInstallRequired = !environment.binariesInstalled
            || !toolLocator.bundledBinariesMatchInstalled()
        if toolInstallRequired {
            log.warning("WireGuard tools require explicit installation or reinstallation in Settings")
            return
        }

        await loadManagedTunnels()

        // Initial status refresh — retry once for login-at-startup timing where
        // the helper XPC channel may still be settling after launchd activation.
        setupStatus = "Refreshing tunnel status…"
        await refreshStatus(reportError: false)
        if statusFailureReported {
            log.info("Initial status refresh failed, retrying in 2s…")
            statusFailureReported = false
            errorMessage = nil
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshStatus(reportError: false)
        }

        // Start polling loop (2s — feeds real-time charts and status)
        startPolling()

        // Run auto-connect check based on current network state at launch
        isLoading = false
        setupStatus = nil
        isInitialized = true
        await handleNetworkChange()
    }

    func redetectEnvironment() async {
        guard !isLoading else {
            log.info("Environment re-detection skipped because another operation is active")
            return
        }

        isLoading = true
        setupStatus = "Re-detecting WireGuard environment…"
        errorMessage = nil
        defer {
            isLoading = false
            setupStatus = nil
        }

        log.info("Environment re-detection started")
        bundledRuntimeStatus = toolLocator.inspectBundledRuntime()
        environment = toolLocator.detect()
        let helperStatus = await effectiveHelperStatus()
        environment.helperInstalled = helperStatus.installed
        helperRequiresApproval = helperStatus.requiresApproval
        toolInstallRequired = !environment.binariesInstalled
            || !toolLocator.bundledBinariesMatchInstalled()

        if helperRequiresApproval {
            // Waiting for user to approve in System Settings — not an error worth surfacing
            log.info("Privileged helper pending approval in System Settings")
            return
        }

        guard environment.helperInstalled else {
            errorMessage = "Privileged helper is not installed."
            log.error(errorMessage ?? "Privileged helper is not installed")
            return
        }

        // Verify helper connectivity, with one retry for daemon startup delay
        setupStatus = "Checking privileged helper…"
        commandService.invalidateConnection()
        var verifiedVersion: String
        do {
            if let knownVersion = helperStatus.version {
                verifiedVersion = knownVersion
            } else {
                verifiedVersion = try await commandService.helperVersion()
            }
        } catch {
            // Daemon may still be starting after approval — wait 2s and retry once
            log.info("Helper check failed, retrying in 2s… (\(error.localizedDescription))")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                verifiedVersion = try await commandService.helperVersion()
            } catch {
                log.error("Helper still unreachable: \(error.localizedDescription)")
                let stale = logHelperLaunchdDiagnostics()
                // Unregister + re-register clears stale BTM/launchd records left
                // behind when the app bundle was replaced after registration.
                do {
                    log.info("Attempting helper re-registration to repair launchd record")
                    setupStatus = "Repairing privileged helper registration…"
                    try await commandService.installHelper(replacingExisting: true)
                    commandService.invalidateConnection()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    verifiedVersion = try await commandService.helperVersion()
                    log.info("Helper reachable after re-registration (version \(verifiedVersion))")
                } catch {
                    helperRequiresApproval = commandService.helperRequiresApproval()
                    logHelperLaunchdDiagnostics()
                    errorMessage = stale
                        ? WireGuardCommandService.staleRegistrationRecoveryMessage
                        : error.localizedDescription
                    log.error("Environment re-detection failed: \(error.localizedDescription)")
                    return
                }
            }
        }
        if await helperNeedsReplacement(version: verifiedVersion) {
            do {
                log.info("Replacing stale same-version privileged helper")
                setupStatus = "Updating privileged helper…"
                try await commandService.installHelper(replacingExisting: true)
                commandService.invalidateConnection()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                verifiedVersion = try await commandService.helperVersion()
                let replacementStillNeeded = await helperNeedsReplacement(version: verifiedVersion)
                guard !replacementStillNeeded else {
                    errorMessage = "Privileged helper is stale. Reinstall the helper."
                    log.error(errorMessage ?? "Privileged helper is stale")
                    return
                }
            } catch {
                errorMessage = error.localizedDescription
                log.error("Privileged helper replacement failed: \(error.localizedDescription)")
                return
            }
        }

        guard !toolInstallRequired else {
            log.info("Helper verified; waiting for explicit WireGuard tool installation")
            return
        }

        await loadManagedTunnels()

        setupStatus = "Refreshing tunnel status…"
        await refreshStatus()
        startPolling()
        log.info("Environment re-detection complete; environment ready")
    }

    /// Logs SMAppService + launchd views of the helper daemon. Returns true when
    /// launchd holds a stale registration it refuses to spawn — the state where
    /// the UI shows "Helper: active" but every XPC call times out.
    @discardableResult
    private func logHelperLaunchdDiagnostics() -> Bool {
        log.info("SMAppService helper status: \(commandService.helperStatusDescription)")
        let diag = WireGuardCommandService.launchdDiagnostics()
        log.error("launchd state for helper: \(diag.summary)")
        if diag.staleRegistration {
            log.error(
                "Diagnosis: stale launchd/BTM registration — launchd keeps the XPC endpoint alive but refuses to spawn the helper (EX_CONFIG / spawn scheduled). Usually caused by replacing the app bundle after registration."
            )
        }
        return diag.staleRegistration
    }

    func refreshHelperRegistrationStatus() async {
        let wasInstalled = environment.helperInstalled
        let requiredApproval = helperRequiresApproval
        let helperStatus = await effectiveHelperStatus()
        let isInstalled = helperStatus.installed
        let nowRequiresApproval = helperStatus.requiresApproval

        if environment.helperInstalled != isInstalled {
            environment.helperInstalled = isInstalled
        }
        if helperRequiresApproval != nowRequiresApproval {
            helperRequiresApproval = nowRequiresApproval
        }

        if isInstalled && !nowRequiresApproval && (!wasInstalled || requiredApproval) {
            await redetectEnvironment()
        }
    }

    func installBundledTools() async {
        isLoading = true
        setupStatus = "Verifying bundled WireGuard tools…"
        errorMessage = nil
        defer {
            isLoading = false
            setupStatus = nil
        }

        guard let bundled = toolLocator.inspectBundledRuntime(), bundled.isValid else {
            let message = bundledRuntimeStatus?.errorMessage ?? "Bundled WireGuard tools failed verification"
            log.error(message)
            errorMessage = message
            return
        }
        bundledRuntimeStatus = bundled

        if !commandService.isHelperInstalled() {
            setupStatus = "Installing privileged helper…"
            do {
                try await commandService.installHelper()
            } catch {
                helperRequiresApproval = commandService.helperRequiresApproval()
                log.error("Helper installation failed: \(error.localizedDescription)")
                let stale = logHelperLaunchdDiagnostics()
                errorMessage = stale
                    ? WireGuardCommandService.staleRegistrationRecoveryMessage
                    : error.localizedDescription
                return
            }
        }

        log.info("Installing verified WireGuard tools from the signed app bundle")
        log.info("  Source: \(bundled.source)")
        for artifact in bundled.artifacts {
            log.info("  \(artifact.name): revision \(artifact.revision), SHA256 \(artifact.expectedSHA256) valid")
        }

        setupStatus = "Installing verified tools…"
        do {
            do {
                try await commandService.installBundledTools()
            } catch {
                // Retry once for transient XPC failures — helper may still be settling
                // after launchd activation (e.g. user just enabled it in Settings).
                let isConnectionError: Bool
                if case CommandError.connectionFailed = error { isConnectionError = true }
                else if case CommandError.connectionInterrupted(_) = error { isConnectionError = true }
                else { isConnectionError = false }
                guard isConnectionError else { throw error }
                setupStatus = "Connecting to privileged helper…"
                commandService.invalidateConnection()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                try await commandService.installBundledTools()
            }
            setupStatus = "Verifying installed tools…"
            environment = toolLocator.detect()
            environment.helperInstalled = commandService.isHelperInstalled()
            toolInstallRequired = !environment.binariesInstalled
                || !toolLocator.bundledBinariesMatchInstalled()
            guard !toolInstallRequired else {
                throw CommandError.installFailed(
                    environment.runtimeStatus?.errorMessage ?? "Installed tools did not match the bundle"
                )
            }
            log.info("WireGuard tools installed and verified successfully")
            await refreshStatus()
            startPolling()
            await handleNetworkChange()
        } catch {
            log.error("WireGuard tool installation failed: \(error.localizedDescription)")
            let stale = logHelperLaunchdDiagnostics()
            errorMessage = stale
                ? WireGuardCommandService.staleRegistrationRecoveryMessage
                : error.localizedDescription
        }
    }

    // MARK: - Tunnel Operations

    func connectTunnel(_ tunnel: Tunnel, isAutoConnect: Bool = false) async {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        let liveTunnel = tunnels[index]
        guard environment.isReady else {
            errorMessage = "Install and verify the bundled WireGuard tools in Settings before connecting."
            return
        }
        if liveTunnel.autoConnectRule.enabled,
           liveTunnel.autoConnectRule.action == .disconnect,
           networkMonitor.matchesTunnel(liveTunnel) {
            errorMessage = "This tunnel is blocked by its on-demand disconnect rule for the current network."
            return
        }
        // Prevent double-connect race: NWPathMonitor fires when wireguard-go creates
        // the utun interface, potentially triggering a second auto-connect before the
        // XPC call for the first one has returned and set isActive = true.
        guard !connectingTunnels.contains(liveTunnel.id) else {
            log.info("Connect already in progress for \(liveTunnel.name), skipping")
            return
        }
        connectingTunnels.insert(liveTunnel.id)
        defer { connectingTunnels.remove(liveTunnel.id) }
        if !isAutoConnect { networkMonitor.userDidConnect(liveTunnel.id) }
        log.info("\(isAutoConnect ? "Auto-connecting" : "Starting") tunnel: \(liveTunnel.name)")

        // Copy config to runtime dir via helper
        let runtimePath = AppPaths.runtimeConfigDir
            .appendingPathComponent(URL(fileURLWithPath: liveTunnel.configPath).lastPathComponent).path

        do {
            if liveTunnel.scope == .managed {
                guard liveTunnel.managedPolicy?.usersCanConnect ?? true else {
                    throw CommandError.managedTunnelFailed("Users are not allowed to connect this managed tunnel")
                }
            }

            let stagedRuntimePath: String
            if liveTunnel.scope == .managed {
                stagedRuntimePath = try await commandService.stageManagedConfig(id: liveTunnel.id)
            } else {
                try await commandService.copyConfig(from: liveTunnel.configPath, to: runtimePath)
                stagedRuntimePath = runtimePath
            }
            try await commandService.startTunnel(configPath: stagedRuntimePath)
            if liveTunnel.scope == .managed {
                do {
                    try await commandService.markManagedTunnelConnected(id: liveTunnel.id)
                } catch {
                    log.warning("Unable to record connected user for \(liveTunnel.name): \(error.localizedDescription)")
                }
            }

            tunnels[index].isActive = true
            tunnels[index].connectedAt = Date()
            tunnels[index].runtimeConfigPath = stagedRuntimePath
            tunnels[index].interfaceName = URL(fileURLWithPath: stagedRuntimePath)
                .deletingPathExtension().lastPathComponent
            tunnels[index].updatedAt = Date()
            savePersonalTunnelsOnly()
            updateWarnings()
            await refreshStatus()
            log.info("Tunnel \(liveTunnel.name) connected")
            try? await notificationService.postConnected(tunnelName: liveTunnel.name)
        } catch {
            log.error("Failed to connect \(liveTunnel.name): \(error.localizedDescription)")
            errorMessage = "Failed to connect \(liveTunnel.name): \(error.localizedDescription)"
            try? await notificationService.postError(
                tunnelName: liveTunnel.name,
                message: error.localizedDescription
            )
        }
    }

    func disconnectTunnel(_ tunnel: Tunnel, isAutoDisconnect: Bool = false) async {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        let liveTunnel = tunnels[index]
        if !isAutoDisconnect { networkMonitor.userDidDisconnect(liveTunnel.id) }
        log.info("\(isAutoDisconnect ? "Auto-disconnecting" : "Stopping") tunnel: \(liveTunnel.name)")

        let configPath = liveTunnel.runtimeConfigPath ?? liveTunnel.configPath

        do {
            if liveTunnel.scope == .managed,
               liveTunnel.managedPolicy?.usersCanDisconnect == false {
                throw CommandError.managedTunnelFailed("Users are not allowed to disconnect this managed tunnel")
            }
            try await commandService.stopTunnel(configPath: configPath)
            if liveTunnel.scope == .managed {
                do {
                    try await commandService.markManagedTunnelDisconnected(id: liveTunnel.id)
                } catch {
                    log.warning("Unable to clear connected user for \(liveTunnel.name): \(error.localizedDescription)")
                }
            }
            tunnels[index].isActive = false
            tunnels[index].connectedAt = nil
            tunnels[index].runtimeConfigPath = nil
            tunnels[index].interfaceName = nil
            tunnels[index].lastHandshake = nil
            tunnels[index].rxBytes = 0
            tunnels[index].txBytes = 0
            tunnels[index].updatedAt = Date()
            trafficHistory.removeValue(forKey: liveTunnel.id)
            trafficSnapshots.removeValue(forKey: liveTunnel.id)
            savePersonalTunnelsOnly()
            updateWarnings()
            log.info("Tunnel \(liveTunnel.name) disconnected")
            try? await notificationService.postDisconnected(tunnelName: liveTunnel.name)
        } catch {
            log.error("Failed to disconnect \(liveTunnel.name): \(error.localizedDescription)")
            errorMessage = "Failed to disconnect \(liveTunnel.name): \(error.localizedDescription)"
            try? await notificationService.postError(
                tunnelName: liveTunnel.name,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Config Management

    func importConfig(from url: URL) async throws {
        log.info("Importing config: \(url.lastPathComponent)")
        let parsed = try parser.parse(contentsOf: url)
        guard parsed.isValid else {
            throw ConfigManagementError.invalidConfiguration(parsed.validationErrors)
        }
        let savedURL = try configStorage.importConfig(from: url)

        let name = savedURL.deletingPathExtension().lastPathComponent
        var tunnel = Tunnel(name: name, configPath: savedURL.path)
        tunnel.address = parsed.address
        tunnel.allowedIPs = parsed.allowedIPs
        tunnel.dns = parsed.dns
        tunnel.endpoint = parsed.endpoint
        tunnel.publicKey = parsed.peerPublicKey

        tunnels.append(tunnel)
        savePersonalTunnelsOnly()
        updateWarnings()
        log.info("Imported tunnel: \(name)")
    }

    func importManagedConfig(from url: URL) async throws {
        log.info("Importing managed config: \(url.lastPathComponent)")
        let parsed = try parser.parse(contentsOf: url)
        guard parsed.isValid else {
            throw ConfigManagementError.invalidConfiguration(parsed.validationErrors)
        }
        let contents = try Data(contentsOf: url, options: .mappedIfSafe)
        try await commandService.installManagedTunnel(
            name: url.deletingPathExtension().lastPathComponent,
            contents: contents
        )
        await loadManagedTunnels()
        updateWarnings()
        log.info("Imported managed tunnel: \(url.lastPathComponent)")
    }

    func makeTunnelShared(_ tunnel: Tunnel) async throws {
        guard let liveTunnel = tunnels.first(where: { $0.id == tunnel.id }),
              liveTunnel.scope == .personal else { return }
        guard !liveTunnel.isActive else {
            throw CommandError.managedTunnelFailed("Disconnect this tunnel before making it shared")
        }
        let configURL = URL(fileURLWithPath: liveTunnel.configPath)
        let contents = try Data(contentsOf: configURL, options: .mappedIfSafe)
        try await commandService.installManagedTunnel(name: liveTunnel.name, contents: contents)
        tunnels.removeAll { $0.id == liveTunnel.id }
        try? configStorage.deleteConfig(at: configURL)
        savePersonalTunnelsOnly()
        await loadManagedTunnels()
        updateWarnings()
        log.info("Made tunnel shared for all users: \(liveTunnel.name)")
    }

    func createTunnel(name: String, configContent: String) async throws {
        let parsed = parser.parse(string: configContent)
        guard parsed.isValid else {
            throw ConfigManagementError.invalidConfiguration(parsed.validationErrors)
        }
        let savedURL = try configStorage.saveConfig(name: name, content: configContent)

        let storedName = savedURL.deletingPathExtension().lastPathComponent
        var tunnel = Tunnel(name: storedName, configPath: savedURL.path)
        tunnel.address = parsed.address
        tunnel.allowedIPs = parsed.allowedIPs
        tunnel.dns = parsed.dns
        tunnel.endpoint = parsed.endpoint
        tunnel.publicKey = parsed.peerPublicKey

        tunnels.append(tunnel)
        savePersonalTunnelsOnly()
        log.info("Created tunnel: \(storedName)")
    }

    func updateTunnel(_ tunnel: Tunnel, name: String, configContent: String) async throws {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        let liveTunnel = tunnels[index]
        guard liveTunnel.scope == .personal else {
            throw CommandError.managedTunnelFailed("Managed tunnels must be edited by an administrator")
        }
        let parsed = parser.parse(string: configContent)
        guard parsed.isValid else {
            throw ConfigManagementError.invalidConfiguration(parsed.validationErrors)
        }
        let isSameConfig = name == liveTunnel.name
        let savedURL = try configStorage.saveConfig(
            name: name,
            content: configContent,
            replacingExisting: isSameConfig
        )
        // Remove old file if renamed
        if name != liveTunnel.name {
            try? configStorage.deleteConfig(at: URL(fileURLWithPath: liveTunnel.configPath))
        }
        tunnels[index].name = name
        tunnels[index].configPath = savedURL.path
        tunnels[index].address = parsed.address
        tunnels[index].allowedIPs = parsed.allowedIPs
        tunnels[index].dns = parsed.dns
        tunnels[index].endpoint = parsed.endpoint
        tunnels[index].publicKey = parsed.peerPublicKey
        tunnels[index].updatedAt = Date()
        savePersonalTunnelsOnly()
        updateWarnings()
        log.info("Updated tunnel: \(name)")
    }

    func deleteTunnel(_ tunnel: Tunnel) {
        guard let liveTunnel = tunnels.first(where: { $0.id == tunnel.id }) else { return }
        guard liveTunnel.scope == .personal else { return }
        tunnels.removeAll { $0.id == tunnel.id }
        try? configStorage.deleteConfig(at: URL(fileURLWithPath: liveTunnel.configPath))
        savePersonalTunnelsOnly()
        updateWarnings()
        log.info("Deleted tunnel: \(liveTunnel.name)")
    }

    func deleteManagedTunnel(_ tunnel: Tunnel) async {
        guard tunnel.scope == .managed else { return }
        do {
            try await commandService.deleteManagedTunnel(id: tunnel.id)
            tunnels.removeAll { $0.id == tunnel.id }
            updateWarnings()
            log.info("Deleted managed tunnel: \(tunnel.name)")
        } catch {
            errorMessage = error.localizedDescription
            log.error("Failed to delete managed tunnel \(tunnel.name): \(error.localizedDescription)")
        }
    }

    func replaceManagedConfig(_ tunnel: Tunnel, with url: URL) async throws {
        guard let liveTunnel = tunnels.first(where: { $0.id == tunnel.id }),
              liveTunnel.scope == .managed else { return }
        let parsed = try parser.parse(contentsOf: url)
        guard parsed.isValid else {
            throw ConfigManagementError.invalidConfiguration(parsed.validationErrors)
        }
        let contents = try Data(contentsOf: url, options: .mappedIfSafe)
        try await commandService.updateManagedTunnel(
            id: liveTunnel.id,
            name: url.deletingPathExtension().lastPathComponent,
            contents: contents,
            policy: liveTunnel.managedPolicy ?? ManagedTunnelPolicy(),
            autoConnectRule: liveTunnel.autoConnectRule
        )
        await loadManagedTunnels()
        updateWarnings()
        log.info("Replaced managed tunnel config: \(liveTunnel.name)")
    }

    func connectedUsers(for tunnel: Tunnel) async throws -> [ManagedTunnelUserSession] {
        guard tunnel.scope == .managed else { return [] }
        return try await commandService.listManagedTunnelUsers(id: tunnel.id)
    }

    func toggleFavorite(_ tunnel: Tunnel) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        guard tunnels[index].scope == .personal else { return }
        tunnels[index].isFavorite.toggle()
        savePersonalTunnelsOnly()
    }

    // MARK: - Status

    func refreshStatus(reportError: Bool = true) async {
        guard await statusMonitor.refresh() else {
            let detail = statusMonitor.lastErrorDescription ?? "Unknown status error"
            guard reportError else {
                statusFailureReported = true
                log.info("Initial status refresh waiting for helper: \(detail)")
                return
            }

            let message = "Unable to refresh tunnel status: \(detail)"
            if !statusFailureReported {
                statusFailureReported = true
                errorMessage = message
                log.warning("\(message); preserving last known tunnel state")
            }
            return
        }
        statusFailureReported = false
        let showRawOutput = UserDefaults.standard.bool(forKey: LogService.showRawOutputPreferenceKey)
        if showRawOutput {
            log.rawOutput("wg show all dump:\n\(statusMonitor.lastRawOutput)")
        }
        // Update tunnel isActive based on wg show output.
        // On macOS with wireguard-go, wg show reports the kernel utun name (e.g. utun4),
        // not the config name (e.g. FMDigitech). Match by name first, then fall back to
        // peer public key, and record the real utun name for future polls.
        var updatedTunnels = tunnels
        for index in updatedTunnels.indices {
            let iface = updatedTunnels[index].interfaceName
                ?? URL(fileURLWithPath: updatedTunnels[index].configPath)
                .deletingPathExtension().lastPathComponent

            let status: TunnelStatus? = statusMonitor.statusMap[iface]
                ?? statusMonitor.statusMap.values.first(where: { s in
                    guard let peerKey = updatedTunnels[index].publicKey else { return false }
                    return s.peers.contains { $0.publicKey == peerKey }
                })

            if let status = status {
                updatedTunnels[index].isActive = true
                // Learn and persist the real kernel interface name (utun*)
                updatedTunnels[index].interfaceName = status.interfaceName
                if let peer = status.peers.first {
                    updatedTunnels[index].lastHandshake = peer.lastHandshake
                    updatedTunnels[index].rxBytes = peer.rxBytes
                    updatedTunnels[index].txBytes = peer.txBytes
                    if !peer.allowedIPs.isEmpty {
                        updatedTunnels[index].allowedIPs = peer.allowedIPs
                    }
                    if let ep = peer.endpoint {
                        updatedTunnels[index].endpoint = ep
                    }
                    recordTrafficSample(
                        tunnelId: updatedTunnels[index].id,
                        rx: peer.rxBytes,
                        tx: peer.txBytes
                    )
                }
            } else {
                // Not in wg show → not active
                if updatedTunnels[index].isActive {
                    updatedTunnels[index].isActive = false
                    updatedTunnels[index].lastHandshake = nil
                    updatedTunnels[index].rxBytes = 0
                    updatedTunnels[index].txBytes = 0
                }
            }
        }
        if updatedTunnels != tunnels {
            tunnels = updatedTunnels
        }
        updateWarnings()
    }

    func startPolling(interval: TimeInterval = 2.0) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard let self else { continue }
                guard !self.isLoading else { continue }
                if self.needsSetup {
                    await self.refreshHelperRegistrationStatus()
                } else if self.hasActiveTunnels {
                    await self.refreshStatus()
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Auto-Connect

    func handleNetworkChange() async {
        guard !isLoading, !needsSetup else { return }

        for tunnel in tunnels {
            guard tunnel.autoConnectRule.enabled else { continue }
            let matches = networkMonitor.matchesTunnel(tunnel)
            if tunnel.autoConnectRule.action == .disconnect {
                if matches, tunnel.isActive {
                    log.info("Auto-disconnect blacklist triggered for \(tunnel.name)")
                    networkMonitor.markAutoDisconnected(tunnel.id)
                    await disconnectTunnel(tunnel, isAutoDisconnect: true)
                }
            } else if matches {
                if !tunnel.isActive && !networkMonitor.isSuppressed(tunnel.id) && !connectingTunnels.contains(tunnel.id) {
                    log.info("Auto-connect triggered for \(tunnel.name)")
                    networkMonitor.markAutoConnected(tunnel.id)
                    await connectTunnel(tunnel, isAutoConnect: true)
                }
            } else {
                // Network no longer matches — clear suppression so it reconnects next time
                networkMonitor.clearSuppression(tunnel.id)
                if tunnel.isActive && networkMonitor.wasAutoConnected(tunnel.id) {
                    log.info("Auto-disconnect triggered for \(tunnel.name)")
                    networkMonitor.markAutoDisconnected(tunnel.id)
                    await disconnectTunnel(tunnel, isAutoDisconnect: true)
                }
            }
        }
    }

    func updateAutoConnectRule(for tunnel: Tunnel, rule: AutoConnectRule) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        guard tunnels[index].scope == .personal else { return }
        tunnels[index].autoConnectRule = rule
        tunnels[index].updatedAt = Date()
        savePersonalTunnelsOnly()
        log.info("Auto-connect rule updated for \(tunnels[index].name): enabled=\(rule.enabled)")
        Task { await handleNetworkChange() }
    }

    // MARK: - Warnings

    private func updateWarnings() {
        var warnings: [TunnelWarning] = []
        let active = tunnels.filter(\.isActive)

        let fullTunnels = active.filter { $0.allowedIPs.contains("0.0.0.0/0") }
        if fullTunnels.count > 1 {
            warnings.append(.multipleFullTunnels(fullTunnels.map(\.name)))
        } else if let fullTunnel = fullTunnels.first {
            warnings.append(.fullTunnelActive(fullTunnel.name))
        }

        for i in active.indices {
            for j in active.index(after: i)..<active.endIndex {
                let aIPs = Set(active[i].allowedIPs)
                let bIPs = Set(active[j].allowedIPs)
                if !aIPs.isEmpty, !aIPs.isDisjoint(with: bIPs) {
                    warnings.append(.overlappingAllowedIPs(active[i].name, active[j].name))
                }
            }
        }

        let activeWithDNS = active.filter { !$0.dns.isEmpty }
        if activeWithDNS.count > 1 {
            let dnsSets = activeWithDNS.map { Set($0.dns) }
            if !dnsSets.dropFirst().allSatisfy({ $0 == dnsSets[0] }) {
                warnings.append(.conflictingDNS(activeWithDNS.map(\.name)))
            }
        }

        if activeWarnings != warnings {
            activeWarnings = warnings
        }
    }

    // MARK: - Helpers

    private func helperNeedsReplacement(version: String) async -> Bool {
        guard version == WireGuardCommandService.expectedHelperVersion else { return true }
        do {
            let revision = try await commandService.helperProtocolRevision()
            if revision != WireGuardCommandService.expectedHelperProtocolRevision {
                log.warning(
                    "Privileged helper protocol revision \(revision) is stale; expected \(WireGuardCommandService.expectedHelperProtocolRevision)"
                )
                return true
            }
            return false
        } catch {
            log.warning("Privileged helper protocol check failed: \(error.localizedDescription)")
            return true
        }
    }

    private func effectiveHelperStatus() async -> (installed: Bool, requiresApproval: Bool, version: String?) {
        var installed = commandService.isHelperInstalled()
        var requiresApproval = commandService.helperRequiresApproval()
        var version: String?
        if requiresApproval || !installed {
            version = try? await commandService.helperVersion()
            if version != nil {
                // ponytail: SMAppService can lag behind launchd; a working XPC ping wins.
                installed = true
                requiresApproval = false
            }
        }
        return (installed, requiresApproval, version)
    }

    private func savePersonalTunnelsOnly() {
        repository.save(tunnels.filter { $0.scope == .personal })
    }

    private func loadManagedTunnels() async {
        do {
            var managed = try await commandService.listManagedTunnels()
            let existingByID = Dictionary(uniqueKeysWithValues: tunnels.map { ($0.id, $0) })
            for index in managed.indices {
                managed[index].scope = .managed
                if let existing = existingByID[managed[index].id] {
                    managed[index].isActive = existing.isActive
                    managed[index].runtimeConfigPath = existing.runtimeConfigPath
                    managed[index].interfaceName = existing.interfaceName
                    managed[index].lastHandshake = existing.lastHandshake
                    managed[index].rxBytes = existing.rxBytes
                    managed[index].txBytes = existing.txBytes
                    managed[index].connectedAt = existing.connectedAt
                }
            }
            tunnels = tunnels.filter { $0.scope == .personal } + managed
            log.info("Loaded \(managed.count) managed tunnels")
        } catch {
            log.warning("Unable to load managed tunnels: \(error.localizedDescription)")
        }
    }

    var needsSetup: Bool {
        helperRequiresApproval || !environment.helperInstalled || toolInstallRequired
    }

    var hasActiveTunnels: Bool { tunnels.contains { $0.isActive } }
    var activeTunnelCount: Int { tunnels.filter { $0.isActive }.count }
    var sharedTunnels: [Tunnel] { tunnels.filter { $0.scope == .managed } }
    var favoriteTunnels: [Tunnel] { tunnels.filter { $0.isFavorite && $0.scope == .personal } }

    private nonisolated static func currentUserIsAdministrator() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/id")
        process.arguments = ["-Gn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return false
        }
        return output.split(whereSeparator: \.isWhitespace).contains("admin")
    }

    func openHelperApprovalSettings() {
        commandService.openHelperApprovalSettings()
    }

    func stopAllActive() async {
        for tunnel in tunnels.filter({ $0.isActive }) {
            await disconnectTunnel(tunnel)
        }
    }

    func startAllFavorites() async {
        for tunnel in tunnels.filter({ $0.isFavorite && !$0.isActive }) {
            await connectTunnel(tunnel)
        }
    }

    func inspectConfig(at url: URL) throws -> ParsedConfig {
        try parser.parse(contentsOf: url)
    }

    func generateKeyPair() async throws -> (privateKey: String, publicKey: String) {
        guard environment.isReady else {
            errorMessage = ConfigManagementError.environmentNotReady.localizedDescription
            throw ConfigManagementError.environmentNotReady
        }
        do {
            return try await commandService.generateKeyPair()
        } catch {
            errorMessage = "Key generation failed: \(error.localizedDescription)"
            log.error(errorMessage ?? "Key generation failed")
            throw error
        }
    }

    @discardableResult
    func resetUserData() async -> Bool {
        var stopFailures: [String] = []
        for tunnel in tunnels.filter(\.isActive) {
            await disconnectTunnel(tunnel)
            if tunnels.first(where: { $0.id == tunnel.id })?.isActive == true {
                stopFailures.append(tunnel.name)
            }
        }

        do {
            let managed = tunnels.filter { $0.scope == .managed }
            try resetService.reset()
            tunnels = managed
            activeWarnings = []
            trafficHistory = [:]
            trafficSnapshots = [:]
            log.clearLog()
            if !stopFailures.isEmpty {
                errorMessage = "App data was reset, but these tunnels could not be stopped: \(stopFailures.joined(separator: ", "))."
            } else {
                errorMessage = nil
            }
            return true
        } catch {
            errorMessage = "Reset app data failed: \(error.localizedDescription)"
            log.error(errorMessage ?? "Reset app data failed")
            return false
        }
    }

    // MARK: - Traffic History

    private func recordTrafficSample(tunnelId: UUID, rx: Int64, tx: Int64) {
        let now = Date()
        defer { trafficSnapshots[tunnelId] = (rx: rx, tx: tx, time: now) }

        guard let prev = trafficSnapshots[tunnelId] else {
            log.info("Traffic snapshot baseline set for \(tunnelId)")
            return
        }
        let dt = now.timeIntervalSince(prev.time)
        guard dt >= 0.5 else { return }

        let rxRate = max(0, Double(rx - prev.rx) / dt)
        let txRate = max(0, Double(tx - prev.tx) / dt)
        let sample = TrafficSample(timestamp: now, rxRate: rxRate, txRate: txRate)

        var samples = trafficHistory[tunnelId, default: []]
        samples.append(sample)
        if samples.count > maxTrafficSamples {
            samples.removeFirst(samples.count - maxTrafficSamples)
        }
        trafficHistory[tunnelId] = samples
    }
}

enum ConfigManagementError: LocalizedError {
    case invalidConfiguration([ConfigValidationError])
    case environmentNotReady

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let errors):
            return "Invalid WireGuard configuration: "
                + errors.map(\.message).joined(separator: "; ")
        case .environmentNotReady:
            return "Install and verify the bundled WireGuard tools before generating keys."
        }
    }
}
