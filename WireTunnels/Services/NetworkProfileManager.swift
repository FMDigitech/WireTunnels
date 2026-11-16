import Combine
import Foundation

/// Picks the network profile that matches the current network and applies it: DNS through the
/// helper and an optional Shortcut. Profiles never connect tunnels; a connected tunnel's DNS wins.
@MainActor
final class NetworkProfileManager: ObservableObject {
    @Published private(set) var profiles: [NetworkProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published var errorMessage: String?
    /// Latency results of the last "Test DNS" run, by server address.
    @Published private(set) var dnsTestResults: [String: DNSProbe.Outcome] = [:]
    @Published private(set) var isTestingDNS = false
    /// Connects or disconnects a tunnel for a profile action. Set by the tunnel manager.
    var performTunnelAction: ((ProfileTunnelAction) async -> Void)?

    private let repository: NetworkProfileRepository
    private let commandService: WireGuardCommandService
    private let networkMonitor: NetworkMonitorService
    private let log: LogService
    // nil until the first evaluation: the helper may still hold DNS from a run that crashed.
    private var appliedDNS: [String]?
    // nil until the first evaluation: the helper may still hold a proxy from a run that crashed.
    private var appliedProxy: ProxySettings??
    @Published private(set) var isFlushingDNS = false
    @Published private(set) var dnsFlushMessage: String?

    var currentSSID: String? { networkMonitor.currentSSID }

    init(commandService: WireGuardCommandService, networkMonitor: NetworkMonitorService,
         repository: NetworkProfileRepository = NetworkProfileRepository(), log: LogService? = nil) {
        self.commandService = commandService
        self.networkMonitor = networkMonitor
        self.repository = repository
        self.log = log ?? .shared
    }

    func load() {
        do {
            profiles = try repository.load()
            if let warning = repository.recoveryWarning { log.warning(warning) }
        } catch {
            errorMessage = "Network profiles could not be read: \(error.localizedDescription)"
        }
    }

    func save(_ updated: [NetworkProfile]) async {
        do {
            try repository.save(updated)
            profiles = updated
            errorMessage = nil
        } catch {
            errorMessage = "Network profiles could not be saved: \(error.localizedDescription)"
            return
        }
        await evaluate()
    }

    /// Runs after every network change, once tunnel rules have settled.
    func evaluate() async {
        let match = NetworkProfileResolver.firstMatch(
            in: profiles, isOnEthernet: networkMonitor.isOnEthernet, ethernetAddresses: networkMonitor.ethernetAddresses,
            isOnWiFi: networkMonitor.isOnWiFi, currentSSID: networkMonitor.currentSSID)
        if match?.id != activeProfileID {
            activeProfileID = match?.id
            if let name = match?.shortcutName { runShortcut(name) }
            for action in match?.tunnelActions ?? [] { await performTunnelAction?(action) }
        }
        await syncDNS(match?.dnsServers ?? [])
        await syncProxy(match?.proxy)
    }

    func releaseOnQuit() async {
        if appliedDNS?.isEmpty == false {
            try? await commandService.releaseProfileDNS()
            appliedDNS = []
        }
        // Whatever the journal holds goes back, even if this run never applied a proxy itself.
        if appliedProxy != .some(nil) {
            try? await commandService.releaseProfileProxy()
            appliedProxy = .some(nil)
        }
    }

    /// Empties the system DNS cache, for the Flush button. Cached answers from the previous resolvers
    /// would otherwise outlive a change of DNS.
    func flushDNSCache() async {
        guard !isFlushingDNS else { return }
        isFlushingDNS = true
        defer { isFlushingDNS = false }
        do {
            try await commandService.flushDNSCache()
            dnsFlushMessage = "DNS cache flushed."
            log.info("DNS cache flushed")
        } catch {
            dnsFlushMessage = error.localizedDescription
            log.warning("DNS cache flush failed: \(error.localizedDescription)")
        }
    }

    /// A change of DNS servers leaves the old answers in the cache: flush after each change.
    private func flushAfterDNSChange() async {
        do { try await commandService.flushDNSCache() }
        catch { log.warning("DNS cache flush after a profile change failed: \(error.localizedDescription)") }
    }

    private func syncProxy(_ wanted: ProxySettings?) async {
        guard let wanted else {
            guard appliedProxy != .some(nil) else { return }
            // No profile wants a proxy now. The first time through, a crashed run may have left one:
            // the helper keeps a journal and only restores when it has one.
            do { try await commandService.releaseProfileProxy() }
            catch { log.info("Profile proxy release: \(error.localizedDescription)") }
            appliedProxy = .some(nil)
            return
        }
        if let problem = wanted.problem {
            errorMessage = "The profile's proxy cannot be applied: \(problem)"
            return
        }
        // Reapplied only when it changes: the helper rewrites system network settings each time.
        guard appliedProxy != .some(wanted) else { return }
        do {
            try await commandService.applyProfileProxy(wanted)
            appliedProxy = .some(wanted)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            log.warning("Network profile proxy failed: \(error.localizedDescription)")
        }
    }

    // shortcut: reapplies on every network change; the helper skips unchanged writes, so it only costs one XPC call.
    private func syncDNS(_ servers: [String]) async {
        if servers.isEmpty {
            guard appliedDNS != [] else { return }
            // Nobody uses profile DNS, so a crashed run cannot have left any behind: skip the helper call.
            if appliedDNS == nil, !profiles.contains(where: { !$0.dnsServers.isEmpty }) {
                appliedDNS = []
                return
            }
            // Standard users cannot release, and have nothing applied: stay quiet.
            do {
                try await commandService.releaseProfileDNS()
                await flushAfterDNSChange()
            } catch { log.info("Profile DNS release: \(error.localizedDescription)") }
            appliedDNS = []
            return
        }
        // The helper skips unchanged writes, so only a real change needs the cache emptied.
        let changed = appliedDNS != servers
        do {
            try await commandService.applyProfileDNS(servers)
            appliedDNS = servers
            errorMessage = nil
            if changed { await flushAfterDNSChange() }
            await releaseIfBlocked(servers)
        } catch {
            errorMessage = error.localizedDescription
            log.warning("Network profile DNS failed: \(error.localizedDescription)")
        }
    }

    /// Measures the servers a profile just applied. If none answers, the chosen DNS blocks the network
    /// (a captive portal, a firewall that only allows its own resolver): give the system DNS back.
    private func releaseIfBlocked(_ servers: [String]) async {
        let results = await DNSProbeClient.measureAll(servers: servers)
        guard DNSProbe.isBlocked(results) else { return }
        // Let the user's own check win if the network changed while probing.
        guard appliedDNS == servers else { return }
        do {
            try await commandService.releaseProfileDNS()
            appliedDNS = []
            await flushAfterDNSChange()
            errorMessage = "None of the DNS servers (\(servers.joined(separator: ", "))) answered on this network, so the system DNS was restored."
            log.warning("Network profile DNS blocked; restored the system DNS")
        } catch {
            errorMessage = "None of the profile's DNS servers answered, and the system DNS could not be restored: \(error.localizedDescription)"
            log.warning("Network profile DNS blocked and release failed: \(error.localizedDescription)")
        }
    }

    /// Measures the latency of `servers` for the editor's "Test DNS" button.
    func testDNS(_ servers: [String]) async {
        guard !servers.isEmpty, !isTestingDNS else { return }
        isTestingDNS = true
        dnsTestResults = [:]
        let results = await DNSProbeClient.measureAll(servers: servers)
        dnsTestResults = Dictionary(uniqueKeysWithValues: results.map { ($0.server, $0.outcome) })
        isTestingDNS = false
    }

    private func runShortcut(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("-") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            log.info("Network profile ran Shortcut \(name)")
        } catch {
            log.warning("Network profile could not run Shortcut \(name): \(error.localizedDescription)")
        }
    }
}
