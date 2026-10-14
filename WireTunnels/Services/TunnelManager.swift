import Foundation
import Combine
import AppKit
import ServiceManagement
import Darwin

@MainActor
final class TunnelManager: ObservableObject {
    @Published var tunnels: [Tunnel] = [] {
        didSet {
            if oldValue.map(\.id) != tunnels.map(\.id) {
                connectionFeedback.retain(tunnelIDs: Set(tunnels.map(\.id)))
            }
        }
    }
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
    @Published var hopChains: [HopChain] = []
    @Published var systemSettings = SystemSettings()
    @Published private(set) var connectionFeedback = TunnelConnectionFeedback()
    let currentUserIsAdministrator = TunnelManager.currentUserIsAdministrator()

    private var trafficSnapshots: [UUID: (rx: Int64, tx: Int64, time: Date)] = [:]
    private let maxTrafficSamples = 20

    let commandService = WireGuardCommandService()
    let networkMonitor = NetworkMonitorService()
    private let repository = TunnelRepository()
    private let hopChainRepository = HopChainRepository()
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
    private var localAddressChangeDebounceTask: Task<Void, Never>?
    /// Guards against overlapping restart passes — a DHCP renewal detected right
    /// around a system wake would otherwise trigger two concurrent stop/start
    /// cycles on the same tunnel interfaces.
    private var isRestartingActiveTunnelInterfaces = false
    private var connectingTunnels: Set<UUID> = []
    private var connectingChains: Set<UUID> = []
    private var statusFailureReported = false
    /// Raw managed-tunnel snapshot from the last successful `loadManagedTunnels()`
    /// call, before live runtime state (isActive/rxBytes/etc.) is merged in — used
    /// to log only on a real change (an admin editing/adding/removing a tunnel),
    /// not on every ~10s poll or every byte of traffic.
    private var lastLoadedManagedTunnels: [Tunnel] = []
    /// Tunnels currently protected by a kill switch, i.e. PF is (or should be)
    /// blocking non-tunnel traffic for them. Not a pure function of `isActive` —
    /// a tunnel that drops unexpectedly stays in this set until it reconnects or
    /// the user explicitly disarms it; that persistence is the entire feature.
    private var killSwitchArmedTunnelIDs: Set<UUID> = []
    /// Last successfully-resolved interface/endpoint per armed tunnel. Kept
    /// independent of `Tunnel.interfaceName`/`endpoint` (which some failure paths
    /// clear back to nil) so a tunnel that drops keeps blocking with the last
    /// rules it was actually armed with, rather than silently losing its entry
    /// the next time any other tunnel's kill switch state changes.
    private var killSwitchLastKnownEntry: [UUID: KillSwitchEntry] = [:]
    private var lastSyncedSplitDNS: [SplitDNSEntry]?

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
        networkMonitor.onSystemWake = { [weak self] in
            await self?.handleSystemWake()
        }
        networkMonitor.onLocalAddressChange = { [weak self] in
            // Same debounce reasoning as onNetworkChange above — coalesce the
            // handful of path updates a single DHCP renewal tends to produce.
            self?.localAddressChangeDebounceTask?.cancel()
            self?.localAddressChangeDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await self?.handleLocalAddressChange()
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

        hopChains = hopChainRepository.load()

        // Backfill publicKey / address for tunnels saved before these fields were populated
        var needsSave = false
        for index in tunnels.indices where tunnels[index].publicKey == nil || tunnels[index].address == nil || tunnels[index].localPublicKey == nil {
            if let parsed = try? parser.parse(contentsOf: URL(fileURLWithPath: tunnels[index].configPath)) {
                if tunnels[index].publicKey == nil, let key = parsed.peerPublicKey {
                    tunnels[index].publicKey = key
                    needsSave = true
                }
                if tunnels[index].address == nil {
                    tunnels[index].address = parsed.address
                    needsSave = true
                }
                if tunnels[index].localPublicKey == nil,
                   let key = parsed.privateKey.flatMap({ WireGuardKey.publicKey(fromPrivateKey: $0) }) {
                    tunnels[index].localPublicKey = key
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

        // Flush any stale kill-switch PF state left over from a previous crash or
        // force-quit, then immediately re-arm protection for tunnels already
        // running (the helper's wg-quick process outlives the app, so a tunnel
        // can still be genuinely connected across a relaunch) before polling or
        // auto-connect starts.
        killSwitchArmedTunnelIDs.removeAll()
        killSwitchLastKnownEntry.removeAll()
        await syncKillSwitchState()
        await syncSplitDNSState()
        for tunnel in tunnels where tunnel.isActive && tunnel.isKillSwitchEnabled {
            await armKillSwitch(for: tunnel)
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

    var menuBarConnectionStatus: TunnelConnectionStatus {
        connectionFeedback.menuBarStatus(hasActiveTunnels: hasActiveTunnels)
    }

    func connectionStatus(for tunnel: Tunnel) -> TunnelConnectionStatus? {
        connectionFeedback.status(for: tunnel.id)
    }

    private func reportTunnelFailure(_ tunnel: Tunnel, message: String, automatic: Bool) async {
        if let alert = connectionFeedback.failed(tunnel.id, message: message, automatic: automatic) {
            errorMessage = alert
            try? await notificationService.postError(tunnelName: tunnel.name, message: message)
        }
    }

    /// - Parameter suppressSystemDNS: When true, the tunnel's own `DNS =` entry is
    ///   dropped from the staged runtime config, so wg-quick never touches system
    ///   DNS for this connection. Used for a hop chain's hop leg: the hop never
    ///   resolves hostnames itself (the exit's endpoint is already resolved to a
    ///   literal IP before the chain connects, see `exitRouteEntry`), and if it also
    ///   applied its own DNS, the exit leg's `networksetup -getdnsservers` snapshot —
    ///   taken as its "pre-tunnel" baseline — would capture the hop's VPN DNS instead
    ///   of the real one, leaving a VPN-looking DNS entry behind after the exit
    ///   disconnects (the hop is still up at that point).
    func connectTunnel(_ tunnel: Tunnel, isAutoConnect: Bool = false, suppressSystemDNS: Bool = false) async {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        let liveTunnel = tunnels[index]
        if let chain = activeOrBusyChain(containing: liveTunnel.id), !connectingChains.contains(chain.id) {
            let message = "\(liveTunnel.name) is part of a multi-hop chain; connect or disconnect the chain instead."
            log.warning(message)
            await reportTunnelFailure(liveTunnel, message: message, automatic: isAutoConnect)
            return
        }
        guard environment.isReady else {
            let message = "Install and verify the bundled WireGuard tools in Settings before connecting."
            log.warning(message)
            await reportTunnelFailure(liveTunnel, message: message, automatic: isAutoConnect)
            return
        }
        if liveTunnel.autoConnectRule.disconnect.enabled,
           networkMonitor.matchesDisconnect(liveTunnel) {
            if !isAutoConnect {
                errorMessage = "This tunnel is blocked by its on-demand disconnect rule for the current network."
            }
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
        connectionFeedback.begin(liveTunnel.id, reconnecting: connectionFeedback.issues[liveTunnel.id] != nil)
        defer {
            connectingTunnels.remove(liveTunnel.id)
            connectionFeedback.finish(liveTunnel.id)
        }
        if !isAutoConnect { networkMonitor.userDidConnect(liveTunnel.id) }
        log.info("\(isAutoConnect ? "Auto-connecting" : "Starting") tunnel: \(liveTunnel.name)")
        let connectStarted = ProcessInfo.processInfo.systemUptime
        log.info("Connect \(liveTunnel.name): active tunnels=\(tunnels.filter(\.isActive).count), scope=\(liveTunnel.scope.rawValue), helper=\(commandService.helperStatusDescription)")

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
                stagedRuntimePath = try await log.timed("Connect \(liveTunnel.name): staging managed config") {
                    try await self.commandService.stageManagedConfig(id: liveTunnel.id)
                }
            } else {
                var sourcePath = liveTunnel.configPath
                var dnsStrippedTempURL: URL?
                // Split DNS replaces the system-wide DNS wg-quick would set with
                // domain-scoped resolvers installed by the helper after connect.
                if suppressSystemDNS || !liveTunnel.effectiveSplitDNSDomains.isEmpty {
                    let tempURL = try Self.writeConfigWithoutDNS(from: liveTunnel.configPath)
                    dnsStrippedTempURL = tempURL
                    sourcePath = tempURL.path
                }
                defer { if let dnsStrippedTempURL { try? FileManager.default.removeItem(at: dnsStrippedTempURL) } }
                try await log.timed("Connect \(liveTunnel.name): staging personal config") {
                    try await self.commandService.copyConfig(from: sourcePath, to: runtimePath)
                }
                stagedRuntimePath = runtimePath
            }
            try await log.timed("Connect \(liveTunnel.name): starting WireGuard") {
                try await self.commandService.startTunnel(configPath: stagedRuntimePath)
            }
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
            let statusConfirmed = await log.timed("Connect \(liveTunnel.name): confirming runtime status") {
                await self.refreshStatus(reportError: !isAutoConnect)
            }
            if tunnels[index].isKillSwitchEnabled {
                await armKillSwitch(for: tunnels[index])
            }
            if !tunnels[index].excludedRoutes.isEmpty {
                await syncExcludedRoutes(for: tunnels[index])
            }
            await syncSplitDNSState()
            connectionFeedback.completeConnection(liveTunnel.id, isActive: statusConfirmed && tunnels[index].isActive)
            if !statusConfirmed || !tunnels[index].isActive {
                log.warning("Tunnel \(liveTunnel.name): startup completed but runtime connection is unconfirmed")
            } else {
                log.info("Tunnel \(liveTunnel.name) connected in \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - connectStarted))s; interface=\(tunnels[index].interfaceName ?? "unknown")")
            }
            if !isAutoConnect && statusConfirmed && tunnels[index].isActive {
                try? await notificationService.postConnected(tunnelName: liveTunnel.name)
            }
        } catch {
            log.error("Failed to connect \(liveTunnel.name) after \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - connectStarted))s: \(error.localizedDescription)")
            await reportTunnelFailure(liveTunnel,
                message: "Failed to connect \(liveTunnel.name): \(error.localizedDescription)",
                automatic: isAutoConnect)
        }
    }

    func disconnectTunnel(_ tunnel: Tunnel, isAutoDisconnect: Bool = false) async {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        let liveTunnel = tunnels[index]
        if let chain = activeOrBusyChain(containing: liveTunnel.id), !connectingChains.contains(chain.id) {
            let message = "\(liveTunnel.name) is part of a multi-hop chain; connect or disconnect the chain instead."
            log.warning(message)
            await reportTunnelFailure(liveTunnel, message: message, automatic: isAutoDisconnect)
            return
        }
        if !isAutoDisconnect { networkMonitor.userDidDisconnect(liveTunnel.id) }
        log.info("\(isAutoDisconnect ? "Auto-disconnecting" : "Stopping") tunnel: \(liveTunnel.name)")
        let disconnectStarted = ProcessInfo.processInfo.systemUptime

        let configPath = liveTunnel.runtimeConfigPath ?? liveTunnel.configPath
        log.info("Disconnect \(liveTunnel.name): runtime config=\(URL(fileURLWithPath: configPath).lastPathComponent), interface=\(liveTunnel.interfaceName ?? "unknown")")

        do {
            if liveTunnel.scope == .managed,
               liveTunnel.managedPolicy?.usersCanDisconnect == false {
                throw CommandError.managedTunnelFailed("Users are not allowed to disconnect this managed tunnel")
            }
            try await commandService.stopTunnel(configPath: configPath)
            if killSwitchArmedTunnelIDs.contains(liveTunnel.id) {
                await disarmKillSwitch(for: liveTunnel)
            }
            if !liveTunnel.excludedRoutes.isEmpty {
                try? await commandService.syncRoutes(ownerId: liveTunnel.id, entries: [])
            }
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
            await syncSplitDNSState()
            connectionFeedback.disconnected(liveTunnel.id)
            log.info("Tunnel \(liveTunnel.name) disconnected in \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - disconnectStarted))s")
            if !isAutoDisconnect {
                try? await notificationService.postDisconnected(tunnelName: liveTunnel.name)
            }
        } catch {
            log.error("Failed to disconnect \(liveTunnel.name) after \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - disconnectStarted))s: \(error.localizedDescription)")
            await reportTunnelFailure(liveTunnel,
                message: "Failed to disconnect \(liveTunnel.name): \(error.localizedDescription)",
                automatic: isAutoDisconnect)
        }
    }

    // MARK: - Config Management

    @discardableResult
    func duplicateTunnel(_ tunnel: Tunnel) throws -> Tunnel {
        guard let source = tunnels.first(where: { $0.id == tunnel.id }) else {
            throw TunnelDuplicationError.tunnelNotFound
        }
        let reservedNames = statusMonitor.statusMap.values.compactMap { $0.runtimeConfigPath }.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        }
        let copy = try TunnelDuplicationService(configStorage: configStorage).duplicate(
            source, existingTunnels: tunnels, reservedConfigNames: reservedNames
        )
        tunnels.append(copy)
        savePersonalTunnelsOnly()
        updateWarnings()
        log.info("Duplicated tunnel: \(source.name) -> \(copy.name)")
        return copy
    }

    func importConfig(from url: URL) async throws {
        log.info("Importing config: \(url.lastPathComponent)")
        let parsed = try parser.parse(contentsOf: url)
        guard parsed.isValid else {
            throw ConfigManagementError.invalidConfiguration(parsed.validationErrors)
        }
        let savedURL = try configStorage.importConfig(from: url)

        // The saved file may carry a shortened interface-safe name; the user keeps the full one.
        let name = ConfigStorageService.sanitize(
            name: url.deletingPathExtension().lastPathComponent
        )
        var tunnel = Tunnel(name: name, configPath: savedURL.path)
        tunnel.address = parsed.address
        tunnel.allowedIPs = parsed.allowedIPs
        tunnel.dns = parsed.dns
        tunnel.endpoint = parsed.endpoint
        tunnel.publicKey = parsed.peerPublicKey
        tunnel.localPublicKey = parsed.privateKey.flatMap { WireGuardKey.publicKey(fromPrivateKey: $0) }

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

        let storedName = ConfigStorageService.sanitize(name: name)
        var tunnel = Tunnel(name: storedName, configPath: savedURL.path)
        tunnel.address = parsed.address
        tunnel.allowedIPs = parsed.allowedIPs
        tunnel.dns = parsed.dns
        tunnel.endpoint = parsed.endpoint
        tunnel.publicKey = parsed.peerPublicKey
        tunnel.localPublicKey = parsed.privateKey.flatMap { WireGuardKey.publicKey(fromPrivateKey: $0) }

        tunnels.append(tunnel)
        savePersonalTunnelsOnly()
        log.info("Created tunnel: \(storedName)")
    }

    func updateTunnel(_ tunnel: Tunnel, name: String, configContent: String) async throws {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        let liveTunnel = tunnels[index]
        let parsed = parser.parse(string: configContent)
        guard parsed.isValid else {
            throw ConfigManagementError.invalidConfiguration(parsed.validationErrors)
        }

        if liveTunnel.scope == .managed {
            guard currentUserIsAdministrator else {
                throw CommandError.managedTunnelFailed("Only an administrator can edit a shared tunnel.")
            }
            try await commandService.updateManagedTunnel(
                id: liveTunnel.id,
                name: name,
                contents: configContent.data(using: .utf8),
                policy: liveTunnel.managedPolicy ?? ManagedTunnelPolicy(),
                autoConnectRule: liveTunnel.autoConnectRule
            )
            await loadManagedTunnels()
            updateWarnings()
            log.info("Updated shared tunnel: \(name)")
            return
        }

        let isSameConfig = name == liveTunnel.name
        let savedURL = try configStorage.saveConfig(
            name: name,
            content: configContent,
            replacingExisting: isSameConfig
        )
        // Remove old file if renamed
        if savedURL.path != liveTunnel.configPath {
            try? configStorage.deleteConfig(at: URL(fileURLWithPath: liveTunnel.configPath))
        }
        tunnels[index].name = name
        tunnels[index].configPath = savedURL.path
        tunnels[index].address = parsed.address
        tunnels[index].allowedIPs = parsed.allowedIPs
        tunnels[index].dns = parsed.dns
        tunnels[index].endpoint = parsed.endpoint
        tunnels[index].publicKey = parsed.peerPublicKey
        tunnels[index].localPublicKey = parsed.privateKey.flatMap { WireGuardKey.publicKey(fromPrivateKey: $0) }
        tunnels[index].updatedAt = Date()
        savePersonalTunnelsOnly()
        updateWarnings()
        log.info("Updated tunnel: \(name)")
    }

    func deleteTunnel(_ tunnel: Tunnel) {
        guard let liveTunnel = tunnels.first(where: { $0.id == tunnel.id }) else { return }
        guard liveTunnel.scope == .personal else { return }
        guard !liveTunnel.isActive, !connectingTunnels.contains(liveTunnel.id) else {
            errorMessage = "Disconnect \(liveTunnel.name) before deleting it."
            return
        }
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

    /// Sets the user-chosen speed-test URL. Pass nil/empty to disable the throughput
    /// probe — there is no built-in default host.
    func updateSpeedTestURL(for tunnel: Tunnel, url: String?) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        guard tunnels[index].scope == .personal else { return }
        tunnels[index].speedTestURL = (url?.isEmpty ?? true) ? nil : url
        tunnels[index].updatedAt = Date()
        savePersonalTunnelsOnly()
    }

    // MARK: - Status

    @discardableResult
    func refreshStatus(reportError: Bool = true) async -> Bool {
        guard await statusMonitor.refresh() else {
            let detail = statusMonitor.lastErrorDescription ?? "Unknown status error"
            guard reportError else {
                statusFailureReported = true
                log.info("Status refresh waiting for helper: \(detail); preserving last known tunnel state")
                return false
            }

            let message = "Unable to refresh tunnel status: \(detail)"
            if !statusFailureReported {
                statusFailureReported = true
                errorMessage = message
                log.warning("\(message); preserving last known tunnel state")
            }
            return false
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
        //
        // utun numbers aren't stable across a stop/start cycle — the kernel can hand
        // a previously-learned name to a *different* tunnel the next time interfaces
        // come up (most likely when several tunnels restart concurrently, e.g. after
        // sleep). So a name match is only trusted once we've confirmed the interface's
        // peer key still belongs to this tunnel; otherwise fall back to searching by
        // peer key, which is what actually identifies the tunnel.
        //
        // Peer public key alone isn't always unique, though: a server operator can
        // reuse the same WireGuard keypair across multiple listening ports to serve
        // distinct configs (e.g. "Endpoint = x.x.x.x:443" and "x.x.x.x:4443" for two
        // different tunnels). When a candidate match's live endpoint port doesn't
        // agree with this tunnel's own configured port, it belongs to that other
        // tunnel, not this one.
        var updatedTunnels = tunnels
        let matched = InterfaceMatcher.assign(
            updatedTunnels.map {
                InterfaceMatcher.Candidate(
                    peerPublicKey: $0.publicKey,
                    localPublicKey: $0.localPublicKey,
                    endpoint: $0.endpoint,
                    interfaceHint: $0.interfaceName
                        ?? URL(fileURLWithPath: $0.configPath).deletingPathExtension().lastPathComponent,
                    configName: URL(fileURLWithPath: $0.configPath).deletingPathExtension().lastPathComponent
                )
            },
            statuses: statusMonitor.statusMap
        )

        for index in updatedTunnels.indices {
            let status = matched[index]

            if let status = status {
                // A snapshot during setup can still show the old interface.
                // Only a completed operation or a later poll confirms recovery.
                if !connectingTunnels.contains(updatedTunnels[index].id),
                   connectionFeedback.issues[updatedTunnels[index].id] != nil {
                    connectionFeedback.connected(updatedTunnels[index].id)
                }
                if !updatedTunnels[index].isActive || updatedTunnels[index].interfaceName != status.interfaceName {
                    log.info("Status \(updatedTunnels[index].name): matched \(status.interfaceName), runtime config=\(status.runtimeConfigPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unresolved")")
                }
                updatedTunnels[index].isActive = true
                // Learn and persist the real kernel interface name (utun*)
                updatedTunnels[index].interfaceName = status.interfaceName
                // The live config can outlast a rename or deletion of the user's
                // profile. Use wg-quick's original file for down and reconnect;
                // an unresolved alias must not erase the path recorded at connect.
                if let runtimePath = status.runtimeConfigPath {
                    if updatedTunnels[index].runtimeConfigPath != runtimePath {
                        log.info("Resolved runtime configuration for \(updatedTunnels[index].name): \(URL(fileURLWithPath: runtimePath).lastPathComponent) (\(status.interfaceName))")
                    }
                    updatedTunnels[index].runtimeConfigPath = runtimePath
                }
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
                    if !connectingTunnels.contains(updatedTunnels[index].id) {
                        connectionFeedback.lost(updatedTunnels[index].id)
                    }
                    log.info("Status \(updatedTunnels[index].name): interface no longer present in the helper snapshot")
                    updatedTunnels[index].isActive = false
                    updatedTunnels[index].lastHandshake = nil
                    updatedTunnels[index].rxBytes = 0
                    updatedTunnels[index].txBytes = 0
                    // Kill switch stays armed here deliberately — an unexpected drop
                    // is exactly what it exists to keep blocking through.
                    if killSwitchArmedTunnelIDs.contains(updatedTunnels[index].id) {
                        let name = updatedTunnels[index].name
                        log.warning("Kill switch engaged: \(name) dropped unexpectedly, blocking traffic")
                    }
                }
            }
        }
        if updatedTunnels != tunnels {
            tunnels = updatedTunnels
        }
        updateWarnings()
        // A tunnel that dropped (or came back) outside our control must not leave its
        // domain-scoped resolvers pointing at an unreachable DNS server.
        await syncSplitDNSState()
        return true
    }

    func startPolling(interval: TimeInterval = 2.0) {
        pollingTask?.cancel()
        var tick = 0
        // Refresh the shared managed-tunnel list roughly every 10s so policy/on-demand
        // changes made by an administrator reach other users' already-running sessions.
        let managedRefreshEveryNTicks = max(1, Int(10.0 / interval))
        // Endpoint DNS re-resolution is a DNS lookup per active tunnel, so it runs far
        // less often than the status poll — roughly once a minute is enough to catch a
        // DDNS change without hammering a resolver.
        let endpointRecheckEveryNTicks = max(1, Int(60.0 / interval))
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard let self else { continue }
                guard !self.isLoading else { continue }
                if self.needsSetup {
                    await self.refreshHelperRegistrationStatus()
                    continue
                }
                if self.hasActiveTunnels {
                    await self.refreshStatus(reportError: false)
                }
                tick += 1
                if tick % managedRefreshEveryNTicks == 0 {
                    await self.loadManagedTunnels()
                }
                if self.hasActiveTunnels && tick % endpointRecheckEveryNTicks == 0 {
                    await self.checkEndpointReResolution()
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Connection Test

    /// On-demand latency check against the tunnel's own configured peer endpoint
    /// (data the user already owns — no third-party host involved). If the user has
    /// set `speedTestURL` (never a built-in default), also runs a throughput probe
    /// against that user-chosen URL.
    func testConnection(for tunnel: Tunnel) async -> ConnectionTestResult {
        guard let endpoint = tunnel.endpoint, let parsed = Self.parseEndpoint(endpoint) else {
            return .unknownEndpoint
        }
        let samples = await Task.detached {
            PingService.measureLatency(host: parsed.host)
        }.value
        guard !samples.isEmpty else { return .unreachable }
        let average = samples.reduce(0, +) / Double(samples.count)

        var throughputMbps: Double?
        if let urlString = tunnel.speedTestURL, !urlString.isEmpty, let url = URL(string: urlString) {
            throughputMbps = await Task.detached {
                await ThroughputProbeService.measureThroughput(url: url)
            }.value
        }
        return .success(averageMs: average, throughputMbps: throughputMbps)
    }

    // MARK: - Auto-Connect

    func handleNetworkChange() async {
        guard !isLoading, !needsSetup else { return }

        for tunnel in tunnels {
            guard tunnel.autoConnectRule.enabled else { continue }
            // A chain member's own auto-connect rule always governs just that one
            // tunnel — it never cascades into bringing up (or tearing down) the
            // whole chain. Multi-hop chains are connected/disconnected as a unit
            // only through the explicit controls in HopChainView.
            // Disconnect takes priority: a network that matches both halves
            // (e.g. "any Wi-Fi" for connect and a specific SSID for disconnect)
            // should not connect.
            if networkMonitor.matchesDisconnect(tunnel) {
                if tunnel.isActive {
                    log.info("Auto-disconnect rule triggered for \(tunnel.name)")
                    networkMonitor.markAutoDisconnected(tunnel.id)
                    await disconnectTunnel(tunnel, isAutoDisconnect: true)
                }
            } else if networkMonitor.matchesConnect(tunnel) {
                if !tunnel.isActive && !networkMonitor.isSuppressed(tunnel.id) && !connectingTunnels.contains(tunnel.id) {
                    log.info("Auto-connect rule triggered for \(tunnel.name)")
                    networkMonitor.markAutoConnected(tunnel.id)
                    await connectTunnel(tunnel, isAutoConnect: true)
                }
            } else {
                // Network no longer matches either half — clear suppression so it reconnects next time
                networkMonitor.clearSuppression(tunnel.id)
                if tunnel.isActive && networkMonitor.wasAutoConnected(tunnel.id) {
                    log.info("Auto-disconnect triggered for \(tunnel.name)")
                    networkMonitor.markAutoDisconnected(tunnel.id)
                    await disconnectTunnel(tunnel, isAutoDisconnect: true)
                }
            }
        }
    }

    /// Restarts every active tunnel's interface after the system wakes from sleep,
    /// then re-evaluates on-demand rules.
    /// A tunnel that reads "connected" in the UI can be dead in practice — the
    /// underlying UDP socket and any dynamic-DNS-resolved peer endpoint can go
    /// stale across sleep, silently dropping traffic until wg-quick is rerun.
    func handleSystemWake() async {
        guard !isLoading, !needsSetup else { return }
        // Network interfaces aren't back immediately on wake; give them a moment
        // to settle before rebuilding tunnel interfaces on top of them.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !isLoading, !needsSetup else { return }

        if tunnels.contains(where: { $0.isActive }) {
            log.info("System wake: reconnecting active tunnel(s)")
            await restartActiveTunnelInterfaces()
            log.info("System wake: reconnect pass complete")
        }

        // On-demand rules also need to run here: if the machine wakes on the same
        // Wi-Fi network it slept on, NWPathMonitor may never fire a fresh path
        // update (no interface change to report), so this is the only place that
        // would otherwise catch a tunnel that should auto-connect/disconnect now.
        await handleNetworkChange()
    }

    /// Called when the primary interface's own IP address changes without an
    /// interface/SSID switch (a DHCP lease renewal). `handleNetworkChange()` alone
    /// doesn't cover this: it only re-evaluates On-Demand connect/disconnect rules,
    /// which don't fire when the matched network hasn't actually changed. Left
    /// alone, an already-active tunnel's WireGuard socket stays bound to the old
    /// local address and silently stops passing traffic — exactly the "tunnel
    /// shows connected but errors until I manually reconnect" symptom this fixes.
    func handleLocalAddressChange() async {
        guard !isLoading, !needsSetup else { return }
        guard tunnels.contains(where: { $0.isActive }) else { return }
        log.info("Local IP address renewed: reconnecting active tunnel(s)")
        await restartActiveTunnelInterfaces()
        log.info("Local IP address change: reconnect pass complete")
    }

    /// Restarts currently-active tunnels' interfaces and re-derives the
    /// kill-switch/exclusion-route/hop-chain state that depends on an interface
    /// name or the default gateway — both of which can change out from under an
    /// active tunnel across a system wake, a DHCP lease renewal, or a peer's DDNS
    /// record changing.
    ///
    /// `onlyTunnelIDs`, when given, scopes the restart to those tunnels instead of
    /// every active one. A system wake or a local IP renewal is a genuinely global
    /// network event, so every active tunnel is plausibly affected — but a single
    /// peer's DNS record changing only affects tunnels connected to that peer, and
    /// bouncing unrelated tunnels for it would be a needless connectivity blip
    /// (including tripping their kill switch for no reason).
    private func restartActiveTunnelInterfaces(onlyTunnelIDs: Set<UUID>? = nil) async {
        guard !isRestartingActiveTunnelInterfaces else { return }
        isRestartingActiveTunnelInterfaces = true
        defer { isRestartingActiveTunnelInterfaces = false }

        func isInScope(_ id: UUID) -> Bool { onlyTunnelIDs?.contains(id) ?? true }

        let activeTunnels = tunnels.filter { $0.isActive && isInScope($0.id) }
        guard !activeTunnels.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for tunnel in activeTunnels {
                group.addTask { [weak self] in
                    await self?.reconnectAfterWake(tunnel)
                }
            }
        }

        await refreshStatus(reportError: false)
        // Re-arm (idempotent) any kill-switch tunnel that's active again — the
        // interface name/endpoint may have changed across the reconnect.
        for tunnel in tunnels where tunnel.isActive && tunnel.isKillSwitchEnabled && isInScope(tunnel.id) {
            await armKillSwitch(for: tunnel)
        }
        // Re-derive exclusion routes too — the default gateway/interface can
        // change across the restart just like the kill switch's interface/endpoint.
        for tunnel in tunnels where tunnel.isActive && !tunnel.excludedRoutes.isEmpty && isInScope(tunnel.id) {
            await syncExcludedRoutes(for: tunnel)
        }
        // Same reasoning for hop chains — each leg's interfaceName can change
        // across the restart above, so the host route needs re-deriving too. Left
        // unscoped: a chain's two tunnel IDs aren't worth cross-referencing against
        // onlyTunnelIDs here, and re-syncing an unaffected chain's route is a cheap,
        // idempotent no-op rather than a real interface bounce.
        for chain in hopChains where chain.isEnabled {
            await reconnectHopChainAfterWake(chain)
        }
    }

    /// Re-resolves each active tunnel's configured `Endpoint` hostname and
    /// restarts any tunnel whose currently-live endpoint (frozen in the kernel
    /// interface since connect, as reported by `wg show` into `tunnel.endpoint`)
    /// no longer matches a fresh lookup. This is the server-side mirror of
    /// `handleLocalAddressChange()` above: wg-quick only resolves `Endpoint =`
    /// once at connect time, so a peer behind DDNS/dynamic DNS whose public IP
    /// changes while the tunnel is still "connected" goes silently dead — the
    /// kernel interface keeps sending to the stale address — until reconnected.
    /// A literal-IP endpoint always re-resolves to itself, so static-IP tunnels
    /// never trigger a restart here.
    private func checkEndpointReResolution() async {
        guard !isLoading, !needsSetup else { return }

        var changedTunnelIDs: Set<UUID> = []
        for tunnel in tunnels where tunnel.isActive {
            guard let liveEndpoint = tunnel.endpoint,
                  let liveHost = Self.parseEndpoint(liveEndpoint)?.host else { continue }
            let configPath = tunnel.runtimeConfigPath ?? tunnel.configPath
            guard let configuredEndpoint = (try? parser.parse(contentsOf: URL(fileURLWithPath: configPath)))?.endpoint,
                  let configuredHost = Self.parseEndpoint(configuredEndpoint)?.host else { continue }
            let resolved = await Task.detached {
                Self.resolveIPLiteral(configuredHost)
            }.value
            guard let freshlyResolved = resolved else { continue }
            if freshlyResolved != liveHost {
                log.info("Endpoint for \(tunnel.name) changed: \(liveHost) -> \(freshlyResolved) (host: \(configuredHost))")
                changedTunnelIDs.insert(tunnel.id)
            }
        }

        guard !changedTunnelIDs.isEmpty else { return }
        log.info("DDNS/endpoint address changed for \(changedTunnelIDs.count) tunnel(s); restarting")
        await restartActiveTunnelInterfaces(onlyTunnelIDs: changedTunnelIDs)
    }

    private func reconnectAfterWake(_ tunnel: Tunnel) async {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        let liveTunnel = tunnels[index]
        guard liveTunnel.isActive else { return }
        // Don't collide with a concurrent user-initiated connect/disconnect or an
        // auto-connect rule firing from the same wake event.
        guard !connectingTunnels.contains(liveTunnel.id) else {
            log.info("Wake reconnect skipped for \(liveTunnel.name), already in progress")
            return
        }
        connectingTunnels.insert(liveTunnel.id)
        connectionFeedback.begin(liveTunnel.id, reconnecting: true)
        defer {
            connectingTunnels.remove(liveTunnel.id)
            connectionFeedback.finish(liveTunnel.id)
        }

        let configPath = liveTunnel.runtimeConfigPath ?? liveTunnel.configPath
        log.info("Wake reconnect: restarting \(liveTunnel.name)")
        do {
            try await commandService.stopTunnel(configPath: configPath)
            try await commandService.startTunnel(configPath: configPath)
            // The restart pass confirms all interfaces together once setup ends.
            // Keep feedback until that snapshot verifies this tunnel is present.
            connectionFeedback.completeConnection(liveTunnel.id, isActive: false)
            log.info("Wake reconnect: \(liveTunnel.name) restarted")
        } catch {
            log.error("Wake reconnect failed for \(liveTunnel.name): \(error.localizedDescription)")
            if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
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
            }
            let message = killSwitchArmedTunnelIDs.contains(liveTunnel.id)
                ? "Lost connection after sleep - kill switch is blocking traffic until it reconnects."
                : "Lost connection after sleep: \(error.localizedDescription)"
            await reportTunnelFailure(liveTunnel, message: message, automatic: true)
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

    /// Admin-only: pushes an on-demand rule to the shared store so it applies to every user of this managed tunnel.
    func updateManagedAutoConnectRule(for tunnel: Tunnel, rule: AutoConnectRule) async throws {
        guard let liveTunnel = tunnels.first(where: { $0.id == tunnel.id }), liveTunnel.scope == .managed else { return }
        guard currentUserIsAdministrator else {
            throw CommandError.managedTunnelFailed("Only an administrator can change on-demand settings for a shared tunnel.")
        }
        try await commandService.updateManagedTunnel(
            id: liveTunnel.id,
            name: liveTunnel.name,
            contents: nil,
            policy: liveTunnel.managedPolicy ?? ManagedTunnelPolicy(),
            autoConnectRule: rule
        )
        await loadManagedTunnels()
        updateWarnings()
        log.info("Auto-connect rule updated for shared tunnel \(liveTunnel.name): enabled=\(rule.enabled)")
        await handleNetworkChange()
    }

    /// Admin-only: sets whether non-admin users may connect and/or disconnect this shared tunnel.
    func updateManagedAccessPolicy(for tunnel: Tunnel, usersCanConnect: Bool, usersCanDisconnect: Bool) async throws {
        guard let liveTunnel = tunnels.first(where: { $0.id == tunnel.id }), liveTunnel.scope == .managed else { return }
        guard currentUserIsAdministrator else {
            throw CommandError.managedTunnelFailed("Only an administrator can change access permissions for a shared tunnel.")
        }
        var policy = liveTunnel.managedPolicy ?? ManagedTunnelPolicy()
        policy.usersCanConnect = usersCanConnect
        policy.usersCanDisconnect = usersCanDisconnect
        try await commandService.updateManagedTunnel(
            id: liveTunnel.id,
            name: liveTunnel.name,
            contents: nil,
            policy: policy,
            autoConnectRule: liveTunnel.autoConnectRule
        )
        await loadManagedTunnels()
        updateWarnings()
        log.info("Access policy updated for shared tunnel \(liveTunnel.name): usersCanConnect=\(usersCanConnect) usersCanDisconnect=\(usersCanDisconnect)")
    }

    // MARK: - System settings

    func loadSystemSettings() async {
        guard let settings = try? await commandService.systemSettings() else { return }
        systemSettings = settings
    }

    /// Admin-only: sets whether turning off "Launch at Login" requires administrator credentials on this Mac.
    func updateRequireAdminToDisableLaunchAtLogin(_ enabled: Bool) async throws {
        guard currentUserIsAdministrator else {
            throw CommandError.managedTunnelFailed("Only an administrator can change this setting.")
        }
        var settings = systemSettings
        settings.requireAdminToDisableLaunchAtLogin = enabled
        try await commandService.updateSystemSettings(settings)
        await loadSystemSettings()
        log.info("System setting updated: requireAdminToDisableLaunchAtLogin=\(enabled)")
    }

    /// Returns true when turning off "Launch at Login" may proceed: either no administrator
    /// requirement is set, or administrator credentials were just provided.
    func authorizeDisablingLaunchAtLogin() async -> Bool {
        await loadSystemSettings()
        guard systemSettings.requireAdminToDisableLaunchAtLogin else { return true }
        do {
            try commandService.authorizeAdministrator()
            return true
        } catch {
            log.info("Disabling Launch at Login was not authorized: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Kill switch

    func updateKillSwitch(for tunnel: Tunnel, enabled: Bool) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        guard tunnels[index].scope == .personal else { return }
        tunnels[index].killSwitchEnabled = enabled
        tunnels[index].updatedAt = Date()
        savePersonalTunnelsOnly()
        log.info("Kill switch updated for \(tunnels[index].name): enabled=\(enabled)")
        let liveTunnel = tunnels[index]
        Task { await applyKillSwitchToggle(for: liveTunnel, enabled: enabled) }
    }

    /// Admin-only: pushes the kill switch flag to the shared store so it applies to every user of this managed tunnel.
    func updateManagedKillSwitch(for tunnel: Tunnel, enabled: Bool) async throws {
        guard let liveTunnel = tunnels.first(where: { $0.id == tunnel.id }), liveTunnel.scope == .managed else { return }
        guard currentUserIsAdministrator else {
            throw CommandError.managedTunnelFailed("Only an administrator can change the kill switch for a shared tunnel.")
        }
        var policy = liveTunnel.managedPolicy ?? ManagedTunnelPolicy()
        policy.killSwitchEnabled = enabled
        try await commandService.updateManagedTunnel(
            id: liveTunnel.id,
            name: liveTunnel.name,
            contents: nil,
            policy: policy,
            autoConnectRule: liveTunnel.autoConnectRule
        )
        await loadManagedTunnels()
        updateWarnings()
        log.info("Kill switch updated for shared tunnel \(liveTunnel.name): enabled=\(enabled)")
        if let refreshed = tunnels.first(where: { $0.id == liveTunnel.id }) {
            await applyKillSwitchToggle(for: refreshed, enabled: enabled)
        }
    }

    /// Applies an on/off toggle immediately rather than waiting for the next
    /// connect/disconnect: arms right away if the tunnel is already connected,
    /// disarms right away regardless of connection state (this is also how a
    /// tunnel stuck blocking after an unexpected drop gets released without
    /// requiring a reconnect).
    private func applyKillSwitchToggle(for tunnel: Tunnel, enabled: Bool) async {
        if enabled {
            if tunnel.isActive {
                await armKillSwitch(for: tunnel)
            }
        } else {
            await disarmKillSwitch(for: tunnel)
        }
    }

    private func armKillSwitch(for tunnel: Tunnel) async {
        guard let interfaceName = tunnel.interfaceName,
              let endpoint = tunnel.endpoint,
              let parsed = Self.parseEndpoint(endpoint)
        else {
            log.warning("Kill switch could not determine tunnel endpoint for \(tunnel.name); leaving traffic unprotected")
            try? await notificationService.postError(
                tunnelName: tunnel.name,
                message: "Kill switch could not be enabled: tunnel endpoint is unknown"
            )
            return
        }
        killSwitchLastKnownEntry[tunnel.id] = KillSwitchEntry(
            interfaceName: interfaceName,
            endpointHost: parsed.host,
            endpointPort: parsed.port
        )
        killSwitchArmedTunnelIDs.insert(tunnel.id)
        await syncKillSwitchState()
        log.info("Kill switch armed for \(tunnel.name)")
    }

    private func disarmKillSwitch(for tunnel: Tunnel) async {
        guard killSwitchArmedTunnelIDs.remove(tunnel.id) != nil else { return }
        killSwitchLastKnownEntry.removeValue(forKey: tunnel.id)
        await syncKillSwitchState()
        log.info("Kill switch disarmed for \(tunnel.name)")
    }

    /// Rebuilds the full kill-switch ruleset from every currently-armed tunnel's
    /// last-known interface/endpoint and pushes it to the helper in one call.
    /// Safe to call after every relevant event — the helper replaces the whole
    /// anchor's contents each time, so this is idempotent.
    private func syncKillSwitchState() async {
        let entries = killSwitchArmedTunnelIDs.compactMap { killSwitchLastKnownEntry[$0] }
        do {
            try await commandService.syncKillSwitch(entries: entries)
        } catch {
            log.error("Failed to sync kill switch rules: \(error.localizedDescription)")
            errorMessage = "Kill switch could not be updated: \(error.localizedDescription)"
        }
        updateWarnings()
    }

    // MARK: - Split DNS

    /// Lowercases and strips wildcard/leading-dot decoration; nil when not a valid domain.
    nonisolated static func normalizedSplitDNSDomain(_ raw: String) -> String? {
        var domain = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if domain.hasPrefix("*.") { domain.removeFirst(2) }
        while domain.hasPrefix(".") { domain.removeFirst() }
        while domain.hasSuffix(".") { domain.removeLast() }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard !domain.isEmpty, domain.utf8.count <= 253,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                      && label.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }
              }) else { return nil }
        return domain
    }

    private static func normalizedUniqueDomains(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains.compactMap(normalizedSplitDNSDomain).filter { seen.insert($0).inserted }
    }

    /// True when changing to `domains` flips split DNS on or off for a connected
    /// tunnel — wg-quick applied (or skipped) the system-wide DNS at connect time, so
    /// only a reconnect makes that part take effect.
    func splitDNSChangeNeedsReconnect(for tunnel: Tunnel, newDomains: [String]) -> Bool {
        guard let live = tunnels.first(where: { $0.id == tunnel.id }), live.isActive else { return false }
        return live.effectiveSplitDNSDomains.isEmpty != Self.normalizedUniqueDomains(newDomains).isEmpty
    }

    /// Sets the domains this personal tunnel's DNS servers answer for, re-syncing the
    /// resolvers immediately and reconnecting when `reconnect` is set.
    func updateSplitDNSDomains(for tunnel: Tunnel, domains: [String], reconnect: Bool = false) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }),
              tunnels[index].scope == .personal else { return }
        tunnels[index].splitDNSDomains = Self.normalizedUniqueDomains(domains)
        tunnels[index].updatedAt = Date()
        savePersonalTunnelsOnly()
        let updated = tunnels[index]
        Task {
            if reconnect && updated.isActive {
                await disconnectTunnel(updated)
                await connectTunnel(updated)
            } else {
                await syncSplitDNSState()
            }
        }
    }

    /// Admin-only: sets the split DNS domains of a shared tunnel (stored in its policy).
    func updateManagedSplitDNSDomains(for tunnel: Tunnel, domains: [String], reconnect: Bool = false) async throws {
        guard let liveTunnel = tunnels.first(where: { $0.id == tunnel.id }), liveTunnel.scope == .managed else { return }
        guard currentUserIsAdministrator else {
            throw CommandError.managedTunnelFailed("Only an administrator can change split DNS for a shared tunnel.")
        }
        var policy = liveTunnel.managedPolicy ?? ManagedTunnelPolicy()
        policy.splitDNSDomains = Self.normalizedUniqueDomains(domains)
        try await commandService.updateManagedTunnel(
            id: liveTunnel.id,
            name: liveTunnel.name,
            contents: nil,
            policy: policy,
            autoConnectRule: liveTunnel.autoConnectRule
        )
        await loadManagedTunnels()
        updateWarnings()
        log.info("Split DNS updated for shared tunnel \(liveTunnel.name)")
        if reconnect, let refreshed = tunnels.first(where: { $0.id == liveTunnel.id }), refreshed.isActive {
            await disconnectTunnel(refreshed)
            await connectTunnel(refreshed)
        } else {
            await syncSplitDNSState()
        }
    }

    /// Pushes the full desired resolver set — every active personal tunnel with split
    /// DNS domains and at least one DNS server — to the helper. Idempotent, and the
    /// helper removes any resolver it owns that is no longer listed.
    private func syncSplitDNSState() async {
        let entries = tunnels.compactMap { tunnel -> SplitDNSEntry? in
            guard tunnel.isActive, !tunnel.effectiveSplitDNSDomains.isEmpty else { return nil }
            let servers = tunnel.dns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !servers.isEmpty else { return nil }
            return SplitDNSEntry(ownerId: tunnel.id.uuidString, domains: tunnel.effectiveSplitDNSDomains, servers: servers)
        }
        guard entries != lastSyncedSplitDNS else { return }
        lastSyncedSplitDNS = entries  // also on failure: retry on the next state change, not every poll
        do {
            try await commandService.syncSplitDNS(entries: entries)
        } catch {
            log.error("Failed to sync split DNS: \(error.localizedDescription)")
            if !entries.isEmpty { errorMessage = "Split DNS could not be applied: \(error.localizedDescription)" }
        }
    }

    // MARK: - Split tunnel exclusions

    /// Sets the tunnel's excluded-CIDR list and, if it's currently connected,
    /// immediately re-syncs the privileged routes to match.
    func updateExcludedRoutes(for tunnel: Tunnel, routes: [String]) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        guard tunnels[index].scope == .personal else { return }
        tunnels[index].excludedRoutes = routes
        tunnels[index].updatedAt = Date()
        savePersonalTunnelsOnly()
        guard tunnels[index].isActive else { return }
        let liveTunnel = tunnels[index]
        Task { await syncExcludedRoutes(for: liveTunnel) }
    }

    /// Installs/updates `tunnel`'s split-tunnel exclusion routes against the
    /// current default gateway, or flushes them if `excludedRoutes` is empty.
    /// A CIDR that isn't actually more specific than anything the tunnel already
    /// routes silently does nothing — there's no real CIDR-overlap check here for
    /// v1, matching `updateWarnings()`'s existing exact-string AllowedIPs comparison.
    private func syncExcludedRoutes(for tunnel: Tunnel) async {
        guard !tunnel.excludedRoutes.isEmpty else {
            try? await commandService.syncRoutes(ownerId: tunnel.id, entries: [])
            return
        }
        let discoveredRoute = await Task.detached {
            DefaultRouteService.currentDefaultRoute()
        }.value
        guard let defaultRoute = discoveredRoute else {
            log.warning("Unable to determine default gateway; skipping route exclusions for \(tunnel.name)")
            return
        }
        let entries = tunnel.excludedRoutes.map { cidr in
            RouteEntry(
                cidr: cidr,
                gateway: defaultRoute.gateway,
                interfaceName: defaultRoute.gateway == nil ? defaultRoute.interfaceName : nil
            )
        }
        do {
            try await commandService.syncRoutes(ownerId: tunnel.id, entries: entries)
        } catch {
            log.warning("Failed to sync route exclusions for \(tunnel.name): \(error.localizedDescription)")
        }
    }

    // MARK: - Multi-hop chains

    /// The enabled chain `tunnelID` belongs to, as hop or exit, if any — regardless
    /// of whether the chain is currently connected. Used to route on-demand
    /// evaluation (`handleNetworkChange`) and chain-pairing exclusivity
    /// (`addHopChain`) through the chain, not the individual tunnel.
    private func chain(containing tunnelID: UUID) -> HopChain? {
        hopChains.first { $0.isEnabled && ($0.hopTunnelID == tunnelID || $0.exitTunnelID == tunnelID) }
    }

    /// The chain `tunnelID` belongs to, but only if that chain is actually fully
    /// established (both legs connected, i.e. brought up as a unit by
    /// `connectHopChain`) or mid-operation — i.e. only when a manual individual
    /// connect/disconnect could actually conflict with it. A chain that exists but
    /// isn't fully up — whether fully disconnected or with only one leg connected
    /// individually, outside the chain flow — shouldn't block using its member
    /// tunnels individually; only `connectTunnel`/`disconnectTunnel` use this.
    ///
    /// This must key off "both legs active", not "either leg active": with the
    /// latter, connecting one member individually (allowed, since the chain wasn't
    /// active yet) would immediately make every future individual disconnect of
    /// that same tunnel look like it conflicts with the chain, trapping the user —
    /// connect would work but disconnect never would, short of finding the chain's
    /// own disconnect control.
    private func activeOrBusyChain(containing tunnelID: UUID) -> HopChain? {
        guard let candidate = chain(containing: tunnelID) else { return nil }
        if connectingChains.contains(candidate.id) { return candidate }
        let hopActive = tunnels.first(where: { $0.id == candidate.hopTunnelID })?.isActive ?? false
        let exitActive = tunnels.first(where: { $0.id == candidate.exitTunnelID })?.isActive ?? false
        return (hopActive && exitActive) ? candidate : nil
    }

    /// Copies `configPath` to a throwaway temp file with any `[Interface] DNS = ...`
    /// line removed, and returns the temp file's URL. Used to stage a hop chain's hop
    /// leg without letting wg-quick touch system DNS for it — see `connectTunnel`'s
    /// `suppressSystemDNS` parameter for why.
    private static func writeConfigWithoutDNS(from configPath: String) throws -> URL {
        let original = try String(contentsOfFile: configPath, encoding: .utf8)
        var inInterfaceSection = false
        let filteredLines = original.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inInterfaceSection = trimmed.caseInsensitiveCompare("[Interface]") == .orderedSame
                return true
            }
            guard inInterfaceSection else { return true }
            let key = trimmed.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return key.caseInsensitiveCompare("DNS") != .orderedSame
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).conf")
        try filteredLines.joined(separator: "\n").write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    func addHopChain(hopTunnelID: UUID, exitTunnelID: UUID) {
        guard hopTunnelID != exitTunnelID else { return }
        guard chain(containing: hopTunnelID) == nil, chain(containing: exitTunnelID) == nil else {
            errorMessage = "One of these tunnels is already part of another multi-hop chain."
            return
        }
        hopChains.append(HopChain(hopTunnelID: hopTunnelID, exitTunnelID: exitTunnelID))
        hopChainRepository.save(hopChains)
    }

    func removeHopChain(_ chain: HopChain) {
        hopChains.removeAll { $0.id == chain.id }
        hopChainRepository.save(hopChains)
    }

    /// Builds the host-route entry that steers `exitTunnel`'s own WireGuard traffic
    /// through `hopInterfaceName` instead of the physical interface, resolving a
    /// hostname endpoint to a literal IP first since `route(8)` needs one.
    private func exitRouteEntry(exitTunnel: Tunnel, hopInterfaceName: String) async -> RouteEntry? {
        guard let endpoint = exitTunnel.endpoint, let parsed = Self.parseEndpoint(endpoint) else { return nil }
        let resolved = await Task.detached {
            Self.resolveIPLiteral(parsed.host)
        }.value
        guard let exitPeerIP = resolved else { return nil }
        return RouteEntry(cidr: "\(exitPeerIP)/32", gateway: nil, interfaceName: hopInterfaceName)
    }

    /// Brings up a hop chain: connects the hop tunnel, routes the exit tunnel's own
    /// WireGuard traffic through the hop's interface via a host route, then connects
    /// the exit tunnel — so the exit server sees the hop's IP, not the real one.
    /// Rolls back everything it started on any failure.
    func connectHopChain(_ chain: HopChain) async {
        guard !connectingChains.contains(chain.id) else { return }
        guard let hop = tunnels.first(where: { $0.id == chain.hopTunnelID }),
              let exit = tunnels.first(where: { $0.id == chain.exitTunnelID }) else {
            errorMessage = "This multi-hop chain refers to a tunnel that no longer exists."
            return
        }
        guard !hop.isActive, !exit.isActive else {
            errorMessage = "Disconnect \(hop.name) and \(exit.name) individually before connecting them as a chain."
            return
        }

        connectingChains.insert(chain.id)
        defer { connectingChains.remove(chain.id) }
        log.info("Connecting hop chain: \(hop.name) -> \(exit.name)")

        await connectTunnel(hop, suppressSystemDNS: true)
        guard let liveHop = tunnels.first(where: { $0.id == hop.id }),
              liveHop.isActive, let hopInterface = liveHop.interfaceName else {
            errorMessage = "Failed to connect hop tunnel \(hop.name); multi-hop chain aborted."
            return
        }

        guard let routeEntry = await exitRouteEntry(exitTunnel: exit, hopInterfaceName: hopInterface) else {
            errorMessage = "Could not resolve \(exit.name)'s endpoint address; multi-hop chain aborted."
            await disconnectTunnel(liveHop)
            return
        }

        do {
            try await commandService.syncRoutes(ownerId: chain.id, entries: [routeEntry])
        } catch {
            errorMessage = "Failed to route \(exit.name) through \(hop.name): \(error.localizedDescription)"
            await disconnectTunnel(liveHop)
            return
        }

        await connectTunnel(exit)
        guard let liveExit = tunnels.first(where: { $0.id == exit.id }), liveExit.isActive else {
            errorMessage = "Failed to connect exit tunnel \(exit.name); rolling back multi-hop chain."
            try? await commandService.syncRoutes(ownerId: chain.id, entries: [])
            await disconnectTunnel(liveHop)
            return
        }
        log.info("Hop chain connected: \(hop.name) -> \(exit.name)")
    }

    /// Tears down a hop chain in reverse order: exit tunnel down, host route
    /// flushed, then hop tunnel down — so the exit's traffic never has to fall back
    /// to a route that's already gone.
    func disconnectHopChain(_ chain: HopChain) async {
        guard !connectingChains.contains(chain.id) else { return }
        connectingChains.insert(chain.id)
        defer { connectingChains.remove(chain.id) }

        if let exit = tunnels.first(where: { $0.id == chain.exitTunnelID }), exit.isActive {
            await disconnectTunnel(exit)
        }
        try? await commandService.syncRoutes(ownerId: chain.id, entries: [])
        if let hop = tunnels.first(where: { $0.id == chain.hopTunnelID }), hop.isActive {
            await disconnectTunnel(hop)
        }
        log.info("Hop chain disconnected: \(chain.hopTunnelID) -> \(chain.exitTunnelID)")
    }

    /// Re-derives the chain's host route after a wake-triggered restart of both
    /// legs — `interfaceName` can change across that restart just like it can for
    /// a standalone tunnel, so the route installed before sleep may now be stale.
    ///
    /// Also handles a subtler case even when the interface *name* doesn't change:
    /// `reconnectAfterWake` tears down and recreates the hop's utun interface
    /// (same name, new kernel object), and the kernel silently drops any route
    /// bound to the old one. A plain re-sync would see the same `RouteEntry`
    /// already tracked by the helper and skip re-issuing `route add` — so this
    /// flushes first to force a genuine re-add regardless of what's tracked.
    private func reconnectHopChainAfterWake(_ chain: HopChain) async {
        guard let hop = tunnels.first(where: { $0.id == chain.hopTunnelID }), hop.isActive,
              let hopInterface = hop.interfaceName,
              let exit = tunnels.first(where: { $0.id == chain.exitTunnelID }), exit.isActive else {
            return
        }
        guard let routeEntry = await exitRouteEntry(exitTunnel: exit, hopInterfaceName: hopInterface) else {
            log.warning("Hop chain wake resync: could not resolve \(exit.name)'s endpoint address")
            return
        }
        do {
            try await commandService.syncRoutes(ownerId: chain.id, entries: [])
            try await commandService.syncRoutes(ownerId: chain.id, entries: [routeEntry])
        } catch {
            log.warning("Hop chain wake resync failed for \(hop.name) -> \(exit.name): \(error.localizedDescription)")
        }
    }

    /// Splits a `wg show`-style endpoint string ("host:port" or "[host]:port" for IPv6) into its parts.
    private static func parseEndpoint(_ endpoint: String) -> (host: String, port: Int)? {
        InterfaceMatcher.parseEndpoint(endpoint)
    }

    /// Resolves `host` to a literal IP address — passes it through unchanged if it
    /// already is one. Used for multi-hop's host route, which needs a literal, not
    /// a hostname. Blocking (DNS lookup) — call from a background task.
    nonisolated private static func resolveIPLiteral(_ host: String) -> String? {
        var addr4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &addr4) }) == 1 { return host }
        var addr6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &addr6) }) == 1 { return host }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }

        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            first.pointee.ai_addr, first.pointee.ai_addrlen,
            &buffer, socklen_t(buffer.count),
            nil, 0,
            NI_NUMERICHOST
        ) == 0 else {
            return nil
        }
        return String(cString: buffer)
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

        for tunnel in tunnels where killSwitchArmedTunnelIDs.contains(tunnel.id) && !tunnel.isActive {
            warnings.append(.killSwitchBlocking(tunnel.name))
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
            let managed = try await commandService.listManagedTunnels()
            let changed = managed != lastLoadedManagedTunnels
            lastLoadedManagedTunnels = managed

            var merged = managed
            let existingByID = Dictionary(uniqueKeysWithValues: tunnels.map { ($0.id, $0) })
            for index in merged.indices {
                merged[index].scope = .managed
                if let existing = existingByID[merged[index].id] {
                    merged[index].isActive = existing.isActive
                    merged[index].runtimeConfigPath = existing.runtimeConfigPath
                    merged[index].interfaceName = existing.interfaceName
                    merged[index].lastHandshake = existing.lastHandshake
                    merged[index].rxBytes = existing.rxBytes
                    merged[index].txBytes = existing.txBytes
                    merged[index].connectedAt = existing.connectedAt
                }
            }
            let updatedTunnels = tunnels.filter { $0.scope == .personal } + merged
            if updatedTunnels != tunnels {
                tunnels = updatedTunnels
            }
            if changed {
                log.info("Loaded \(merged.count) managed tunnels")
            }
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
        // Chains first — disconnectHopChain tears down exit-then-hop in the right
        // order, so an individual disconnectTunnel below never fights over a hop
        // interface a still-active exit's route depends on.
        for chain in hopChains where chain.isEnabled {
            let hopActive = tunnels.first(where: { $0.id == chain.hopTunnelID })?.isActive ?? false
            let exitActive = tunnels.first(where: { $0.id == chain.exitTunnelID })?.isActive ?? false
            if hopActive || exitActive {
                await disconnectHopChain(chain)
            }
        }
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

enum ConnectionTestResult {
    case success(averageMs: Double, throughputMbps: Double?)
    case unreachable
    case unknownEndpoint
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
