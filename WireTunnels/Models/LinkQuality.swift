import Foundation

/// Good / Fair / Poor verdict shown next to a tunnel. `unmeasured` is not "bad": it means no
/// probe has produced a value yet (monitoring off, tunnel down, or the window is still filling).
nonisolated enum QualityLevel: String, Equatable {
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
    case unmeasured = "Not measured"
}

/// The limits that turn a latency and a loss figure into a verdict. The defaults are a starting
/// point the user can change in Settings › Monitoring, not a standard.
nonisolated struct QualityThresholds: Codable, Equatable {
    var fairPingMs: Double = 60
    var poorPingMs: Double = 150
    var fairLossPercent: Double = 1
    var poorLossPercent: Double = 3

    static let standard = QualityThresholds()

    /// Fair limits must sit below poor limits, and nothing may be negative.
    var isValid: Bool {
        fairPingMs > 0 && fairLossPercent >= 0
            && fairPingMs < poorPingMs && fairLossPercent < poorLossPercent
    }

    func level(for stats: LinkQualityStats) -> QualityLevel {
        guard let median = stats.medianMs else { return stats.sent > 0 ? .poor : .unmeasured }
        if median >= poorPingMs || stats.lossPercent >= poorLossPercent { return .poor }
        if median >= fairPingMs || stats.lossPercent >= fairLossPercent { return .fair }
        return .good
    }
}

/// One probe: `latencyMs == nil` means the probe got no reply.
nonisolated struct ProbeSample: Equatable {
    let time: Date
    let latencyMs: Double?
}

/// Latency and loss over a window of probes. "95% under" is the p95: not a maximum.
nonisolated struct LinkQualityStats: Equatable {
    let sent: Int
    let lost: Int
    let medianMs: Double?
    let p95Ms: Double?

    var lossPercent: Double { sent == 0 ? 0 : Double(lost) / Double(sent) * 100 }
    var isMeasured: Bool { sent > 0 }

    init(samples: [ProbeSample]) {
        sent = samples.count
        lost = samples.filter { $0.latencyMs == nil }.count
        let values = samples.compactMap(\.latencyMs).sorted()
        medianMs = Self.percentile(values, 0.5)
        p95Ms = Self.percentile(values, 0.95)
    }

    /// Nearest-rank percentile; nil for an empty list.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}

/// A traffic rate for people: Mbps from 1 Mbps up, kbps below, so a quiet tunnel reads "350 kbps"
/// and never "0.0 Mbps". Only an exact zero reads zero.
nonisolated enum RateFormat {
    static func text(mbps value: Double) -> String {
        if value >= 100 { return String(format: "%.0f Mbps", value) }
        if value >= 1 { return String(format: "%.1f Mbps", value) }
        let kbps = value * 1_000
        if kbps >= 100 { return String(format: "%.0f kbps", kbps) }
        if kbps >= 1 { return String(format: "%.1f kbps", kbps) }
        return value > 0 ? "<1 kbps" : "0 kbps"
    }
}

/// How often and for how long the optional active probes run.
nonisolated struct ProbePlan: Equatable {
    static let intervals: [Int] = [5, 10, 30, 60]
    static let retentionHours: [Int] = [1, 6, 24]
    /// Rough wire cost used for the Settings preview; stated there as approximate.
    static let bytesPerProbe = 300
    static let bytesPerStoredSample = 120

    var intervalSeconds: Int
    var retentionHours: Int

    var probesPerDay: Int { 86_400 / max(intervalSeconds, 1) }
    var samplesKept: Int { retentionHours * 3_600 / max(intervalSeconds, 1) }
    var trafficPerDayBytes: Int { probesPerDay * Self.bytesPerProbe }
    var memoryBytesPerTunnel: Int { samplesKept * Self.bytesPerStoredSample }
}
