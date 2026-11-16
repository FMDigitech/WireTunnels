import Foundation
import Combine

/// What the user chose in Settings › Monitoring. Probes are opt-in: nothing is sent until `enabled`.
struct MonitoringSettings: Codable, Equatable {
    var enabled = false
    /// Empty = ping each tunnel's own server (outside the tunnel); otherwise a host probed through the tunnel.
    var destination = ""
    var intervalSeconds = 10
    var retentionHours = 6
    var thresholds = QualityThresholds.standard

    var plan: ProbePlan { ProbePlan(intervalSeconds: intervalSeconds, retentionHours: retentionHours) }

    /// Why the settings cannot be applied yet, shown next to the field. nil = valid.
    var validationMessage: String? {
        if !ProbePlan.intervals.contains(intervalSeconds) { return "Pick one of the listed intervals." }
        if !thresholds.isValid { return "Fair limits must be lower than Poor limits." }
        let host = destination.trimmingCharacters(in: .whitespaces)
        if !host.isEmpty, host.rangeOfCharacter(from: CharacterSet(charactersIn: " /\\\"'`;&|<>$")) != nil {
            return "Use a host name or an IP address, nothing else."
        }
        return nil
    }
}

struct TrafficPoint: Identifiable {
    let id = UUID()
    let time: Date
    let rxMbps: Double
    let txMbps: Double
}

struct TunnelEvent: Identifiable {
    enum Kind: String, CaseIterable {
        case connected = "Connected", handshake = "Handshake", reconnect = "Reconnect"
        case disconnected = "Disconnect", error = "Error"
    }
    let id = UUID()
    let time: Date
    let tunnelID: UUID
    let tunnelName: String
    let kind: Kind
    let detail: String
}

/// Keeps what the dashboard needs to answer "how is it doing, and when did it change":
/// optional latency/loss probes, a long traffic history and a per-tunnel event list.
/// Everything lives in memory only and is cleared when the app quits.
@MainActor
final class LinkQualityMonitor: ObservableObject {
    private static let defaultsKey = "monitoring.settings"
    private static let trafficSpacing: TimeInterval = 5
    private static let reconnectWindow: TimeInterval = 90
    private static let maxEvents = 500

    @Published private(set) var settings: MonitoringSettings
    @Published private(set) var probes: [UUID: [ProbeSample]] = [:]
    @Published private(set) var traffic: [UUID: [TrafficPoint]] = [:]
    @Published private(set) var events: [TunnelEvent] = []
    @Published private(set) var lastProbeAt: Date?

    private let defaults: UserDefaults
    private var probeTask: Task<Void, Never>?
    private var activeTunnels: () -> [Tunnel] = { [] }
    private var known: [UUID: (active: Bool, handshake: Date?)] = [:]
    private var lastDisconnect: [UUID: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(MonitoringSettings.self, from: data) {
            settings = saved
        } else {
            settings = MonitoringSettings()
        }
    }

    // MARK: Settings

    /// Saves valid settings and restarts the probe loop. Returns the reason when they are not valid.
    @discardableResult
    func apply(_ new: MonitoringSettings) -> String? {
        if let message = new.validationMessage { return message }
        settings = new
        defaults.set(try? JSONEncoder().encode(new), forKey: Self.defaultsKey)
        if !new.enabled { probes = [:] }
        restartProbing()
        return nil
    }

    // MARK: Recording

    /// Called with every tunnel list change; turns state changes into events.
    func observe(_ tunnels: [Tunnel]) {
        let now = Date()
        for tunnel in tunnels {
            let before = known[tunnel.id]
            known[tunnel.id] = (tunnel.isActive, tunnel.lastHandshake)
            guard let before else { continue }
            if tunnel.isActive && !before.active {
                let quick = lastDisconnect[tunnel.id].map { now.timeIntervalSince($0) < Self.reconnectWindow } ?? false
                add(tunnel, quick ? .reconnect : .connected, quick ? "Reconnected after a short interruption" : "Tunnel is up")
            } else if !tunnel.isActive && before.active {
                lastDisconnect[tunnel.id] = now
                add(tunnel, .disconnected, "Tunnel is down")
            } else if tunnel.isActive, let handshake = tunnel.lastHandshake, handshake != before.handshake {
                add(tunnel, .handshake, "Handshake completed")
            }
        }
        known = known.filter { entry in tunnels.contains { $0.id == entry.key } }
    }

    func recordError(_ tunnel: Tunnel, message: String) { add(tunnel, .error, message) }

    func recordTraffic(tunnelID: UUID, rxBytesPerSecond: Double, txBytesPerSecond: Double, at time: Date = Date()) {
        var points = traffic[tunnelID, default: []]
        if let last = points.last, time.timeIntervalSince(last.time) < Self.trafficSpacing { return }
        points.append(TrafficPoint(time: time, rxMbps: rxBytesPerSecond * 8 / 1_000_000,
                                   txMbps: txBytesPerSecond * 8 / 1_000_000))
        let cutoff = time.addingTimeInterval(-24 * 3600)
        if let first = points.first, first.time < cutoff { points.removeAll { $0.time < cutoff } }
        traffic[tunnelID] = points
    }

    private func add(_ tunnel: Tunnel, _ kind: TunnelEvent.Kind, _ detail: String) {
        events.insert(TunnelEvent(time: Date(), tunnelID: tunnel.id, tunnelName: tunnel.name, kind: kind, detail: detail), at: 0)
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
    }

    // MARK: Reading

    func events(for tunnelID: UUID) -> [TunnelEvent] { events.filter { $0.tunnelID == tunnelID } }

    func stats(for tunnelID: UUID, window: TimeInterval = 300) -> LinkQualityStats {
        let since = Date().addingTimeInterval(-window)
        return LinkQualityStats(samples: (probes[tunnelID] ?? []).filter { $0.time >= since })
    }

    /// Not measured unless monitoring is on and the tunnel has live probes.
    func quality(for tunnel: Tunnel) -> QualityLevel {
        guard settings.enabled, tunnel.isActive else { return .unmeasured }
        return settings.thresholds.level(for: stats(for: tunnel.id))
    }

    func probeSamples(for tunnelID: UUID, since: Date) -> [ProbeSample] {
        (probes[tunnelID] ?? []).filter { $0.time >= since }
    }

    func trafficPoints(for tunnelID: UUID, since: Date) -> [TrafficPoint] {
        (traffic[tunnelID] ?? []).filter { $0.time >= since }
    }

    // MARK: Probing

    func attach(activeTunnels: @escaping () -> [Tunnel]) {
        self.activeTunnels = activeTunnels
        restartProbing()
    }

    private func restartProbing() {
        probeTask?.cancel()
        guard settings.enabled else { probeTask = nil; return }
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.probeOnce()
                try? await Task.sleep(for: .seconds(self.settings.intervalSeconds))
            }
        }
    }

    private func probeOnce() async {
        let destination = settings.destination.trimmingCharacters(in: .whitespaces)
        let targets: [(UUID, String, String?)] = activeTunnels().compactMap { tunnel in
            if !destination.isEmpty {
                let bound = tunnel.interfaceName.flatMap { $0.hasPrefix("utun") ? $0 : nil }
                return (tunnel.id, destination, bound)
            }
            guard let endpoint = tunnel.endpoint, let host = InterfaceMatcher.parseEndpoint(endpoint)?.host else { return nil }
            return (tunnel.id, host, nil)
        }
        let results = await withTaskGroup(of: (UUID, Double?).self) { group in
            for (id, host, bound) in targets {
                group.addTask {
                    let replies = await Task.detached {
                        PingService.measureLatency(host: host, count: 1, timeoutSeconds: 2, boundInterface: bound)
                    }.value
                    return (id, replies.first)
                }
            }
            var collected: [(UUID, Double?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        let now = Date()
        let cutoff = now.addingTimeInterval(-Double(settings.retentionHours) * 3600)
        for (id, latency) in results {
            var samples = probes[id, default: []]
            samples.append(ProbeSample(time: now, latencyMs: latency))
            if let first = samples.first, first.time < cutoff { samples.removeAll { $0.time < cutoff } }
            probes[id] = samples
        }
        lastProbeAt = now
    }
}
