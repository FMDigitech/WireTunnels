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

        // Load persisted tunnels first
        tunnels = repository.load()
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
        if needsSave { repository.save(tunnels) }

        // Detect environment
        setupStatus = "Detecting environment…"
        errorMessage = nil
        bundledRuntimeStatus = toolLocator.inspectBundledRuntime()
        environment = toolLocator.detect()
        environment.helperInstalled = commandService.isHelperInstalled()
        helperRequiresApproval = commandService.helperRequiresApproval()

        if helperRequiresApproval {
            let message = "Enable the privileged helper in System Settings, then run Re-detect."
            log.error(message)
            errorMessage = message
            return
        }

        var helperNeedsReplacement = false
        if environment.helperInstalled {
            setupStatus = "Checking privileged helper…"
            do {
                let version = try await commandService.helperVersion()
                log.info("Privileged helper reachable (version \(version))")
                if version != WireGuardCommandService.expectedHelperVersion {
                    helperNeedsReplacement = true
                    log.warning(
                        "Privileged helper version \(version) is stale; expected \(WireGuardCommandService.expectedHelperVersion)"
                    )
                }
            } catch {
                // Daemon may still be starting — wait 2s and retry once before replacing
                log.info("Helper check failed, retrying in 2s… (\(error.localizedDescription))")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    let version = try await commandService.helperVersion()
                    log.info("Privileged helper reachable after retry (version \(version))")
                    if version != WireGuardCommandService.expectedHelperVersion {
                        helperNeedsReplacement = true
                        log.warning(
                            "Privileged helper version \(version) is stale; expected \(WireGuardCommandService.expectedHelperVersion)"
                        )
                    }
                } catch {
                    helperNeedsReplacement = true
                    log.error("Registered helper is unreachable: \(error.localizedDescription)")
                }
            }
        }

        // Install helper if needed, replacing stale registrations that cannot launch.
        if !environment.helperInstalled || helperNeedsReplacement {
            setupStatus = "Installing privileged helper (system prompt may appear)…"
            do {
                log.info(helperNeedsReplacement
                         ? "Replacing stale privileged helper"
                         : "Installing privileged helper")
                try await commandService.installHelper(replacingExisting: helperNeedsReplacement)
                environment.helperInstalled = true
                helperRequiresApproval = false
                log.info("Helper installed successfully")
            } catch {
                helperRequiresApproval = commandService.helperRequiresApproval()
                log.error("Helper installation failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                return
            }
        }

        toolInstallRequired = !environment.binariesInstalled
            || !toolLocator.bundledBinariesMatchInstalled()
        if toolInstallRequired {
            log.warning("WireGuard tools require explicit installation or reinstallation in Settings")
            return
        }

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
        environment.helperInstalled = commandService.isHelperInstalled()
        helperRequiresApproval = commandService.helperRequiresApproval()
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
            verifiedVersion = try await commandService.helperVersion()
        } catch {
            // Daemon may still be starting after approval — wait 2s and retry once
            log.info("Helper check failed, retrying in 2s… (\(error.localizedDescription))")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                verifiedVersion = try await commandService.helperVersion()
            } catch {
                errorMessage = error.localizedDescription
                log.error("Environment re-detection failed: \(error.localizedDescription)")
                return
            }
        }
        guard verifiedVersion == WireGuardCommandService.expectedHelperVersion else {
            errorMessage = "Privileged helper version \(verifiedVersion) is stale. Reinstall the helper."
            log.error(errorMessage ?? "Privileged helper version is stale")
            return
        }

        guard !toolInstallRequired else {
            log.info("Helper verified; waiting for explicit WireGuard tool installation")
            return
        }

        setupStatus = "Refreshing tunnel status…"
        await refreshStatus()
        startPolling()
        log.info("Environment re-detection complete; environment ready")
    }

    func refreshHelperRegistrationStatus() async {
        let wasInstalled = environment.helperInstalled
        let requiredApproval = helperRequiresApproval
        let isInstalled = commandService.isHelperInstalled()
        let nowRequiresApproval = commandService.helperRequiresApproval()

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
                errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
            try await commandService.copyConfig(from: liveTunnel.configPath, to: runtimePath)
            try await commandService.startTunnel(configPath: runtimePath)

            tunnels[index].isActive = true
            tunnels[index].connectedAt = Date()
            tunnels[index].runtimeConfigPath = runtimePath
            tunnels[index].interfaceName = URL(fileURLWithPath: liveTunnel.configPath)
                .deletingPathExtension().lastPathComponent
            tunnels[index].updatedAt = Date()
            repository.save(tunnels)
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
            try await commandService.stopTunnel(configPath: configPath)
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
            repository.save(tunnels)
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
        repository.save(tunnels)
        updateWarnings()
        log.info("Imported tunnel: \(name)")
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
        repository.save(tunnels)
        log.info("Created tunnel: \(storedName)")
    }

    func updateTunnel(_ tunnel: Tunnel, name: String, configContent: String) async throws {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        let liveTunnel = tunnels[index]
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
        repository.save(tunnels)
        updateWarnings()
        log.info("Updated tunnel: \(name)")
    }

    func deleteTunnel(_ tunnel: Tunnel) {
        guard let liveTunnel = tunnels.first(where: { $0.id == tunnel.id }) else { return }
        tunnels.removeAll { $0.id == tunnel.id }
        try? configStorage.deleteConfig(at: URL(fileURLWithPath: liveTunnel.configPath))
        repository.save(tunnels)
        updateWarnings()
        log.info("Deleted tunnel: \(liveTunnel.name)")
    }

    func toggleFavorite(_ tunnel: Tunnel) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        tunnels[index].isFavorite.toggle()
        repository.save(tunnels)
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
            if matches {
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
        tunnels[index].autoConnectRule = rule
        tunnels[index].updatedAt = Date()
        repository.save(tunnels)
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

    var needsSetup: Bool {
        helperRequiresApproval || !environment.helperInstalled || toolInstallRequired
    }

    var hasActiveTunnels: Bool { tunnels.contains { $0.isActive } }
    var activeTunnelCount: Int { tunnels.filter { $0.isActive }.count }
    var favoriteTunnels: [Tunnel] { tunnels.filter { $0.isFavorite } }

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
            try resetService.reset()
            tunnels = []
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
