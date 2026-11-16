import SwiftUI

/// Overview tab of a tunnel: verdict, speed over time, the figures behind the verdict, and what happened.
struct TunnelOverviewTab: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var monitor: LinkQualityMonitor
    @EnvironmentObject var navigation: DashboardNavigation
    let tunnel: Tunnel
    @State private var range: ChartRange = .minutes15

    private var stats: LinkQualityStats { monitor.stats(for: tunnel.id) }
    private var quality: QualityLevel { monitor.quality(for: tunnel) }
    private var lastReconnect: TunnelEvent? { monitor.events(for: tunnel.id).first { $0.kind == .reconnect } }

    private var verdict: (tone: StatusTone, title: String, message: String) {
        if !tunnel.isActive {
            return (.neutral, "Not connected", "Connect the tunnel to see live speed and quality. Past events stay below.")
        }
        if !monitor.settings.enabled {
            return (.neutral, "Quality not measured", "Latency and packet loss need the optional probes. Speed and handshake come from the tunnel itself and are always shown.")
        }
        guard stats.isMeasured else {
            return (.info, "Measuring…", "The first probes are running. The verdict appears after a few replies.")
        }
        let reconnect = lastReconnect.map { " Reconnected automatically at \(Format.clock($0.time))." } ?? ""
        switch quality {
        case .good: return (.good, "Good quality", "Fast and stable. Latency is low and almost no packets are lost.\(reconnect)")
        case .fair: return (.warn, "Fair quality", "Usable, but latency or packet loss is above the Good limits.\(reconnect)")
        default: return (.bad, "Poor quality", "Latency or packet loss is above the Poor limits. Check Network Doctor and the log.\(reconnect)")
        }
    }

    var body: some View {
        let v = verdict
        VStack(alignment: .leading, spacing: 16) {
            Notice(tone: v.tone, title: v.title, message: v.message)
            if tunnel.isActive && !monitor.settings.enabled {
                Button("Turn on monitoring…") { navigation.requestSidebar(.settings) }
                    .buttonStyle(.link)
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            PaneSectionHeader(title: "Speed over time",
                                              note: "Measured on this device · \(tunnel.isActive ? "updated \(Format.clock(Date()))" : "tunnel is off")")
                            Spacer()
                            RangePicker(range: $range)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            PaneSectionHeader(title: "Speed over time",
                                              note: "Measured on this device · \(tunnel.isActive ? "updated \(Format.clock(Date()))" : "tunnel is off")")
                            RangePicker(range: $range)
                        }
                    }
                    SpeedChart(points: monitor.trafficPoints(for: tunnel.id, since: Date().addingTimeInterval(-range.seconds)),
                               range: range,
                               markers: monitor.events(for: tunnel.id).filter { $0.kind == .reconnect }.map(\.time))
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    PaneSectionHeader(title: "Quality",
                                      note: monitor.settings.enabled ? probeNote : "Optional probes are off. Turn them on in Settings › Monitoring.")
                    if !monitor.settings.enabled {
                        Button("Turn on monitoring…") { navigation.requestSidebar(.settings) }
                            .buttonStyle(.link)
                    }
                    MetricGrid(minimum: 120) {
                        Metric(label: "Latency (ping)", value: Format.ms(stats.medianMs), note: stats.isMeasured ? "typical" : "not measured")
                        Metric(label: "95% under", value: Format.ms(stats.p95Ms), note: stats.isMeasured ? "slowest 5% excluded" : nil)
                        Metric(label: "Packet loss",
                               value: stats.isMeasured ? String(format: "%.1f%%", stats.lossPercent) : "—",
                               note: stats.isMeasured ? "\(stats.lost) of \(stats.sent) probes lost" : nil)
                    }
                    if monitor.settings.enabled && monitor.probeSamples(for: tunnel.id, since: Date().addingTimeInterval(-range.seconds)).count > 1 {
                        LatencyChart(samples: monitor.probeSamples(for: tunnel.id, since: Date().addingTimeInterval(-range.seconds)), range: range)
                    }
                }
            }

            Card {
                MetricGrid(minimum: 120) {
                    Metric(label: "Connected for", value: tunnel.connectedAt.map { Format.duration(since: $0) } ?? "—")
                    Metric(label: "Last handshake", value: Format.ago(tunnel.lastHandshake), note: "alone it does not prove the path works")
                    Metric(label: "Received", value: formatBytes(tunnel.rxBytes), note: tunnel.isActive ? "since connecting" : nil)
                    Metric(label: "Sent", value: formatBytes(tunnel.txBytes), note: tunnel.isActive ? "since connecting" : nil)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    PaneSectionHeader(title: "Recent activity", note: "Events are kept in memory until the app quits. Nearby lines are context, not proof of a cause.")
                    let events = Array(monitor.events(for: tunnel.id).prefix(8))
                    if events.isEmpty {
                        Text("No events yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(events) { event in
                        HStack(spacing: 10) {
                            Text(Format.clock(event.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            StatusPill(text: event.kind.rawValue, tone: tone(for: event.kind), showsIcon: false)
                            Text(event.detail).font(.callout).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var probeNote: String {
        let target = monitor.settings.destination.isEmpty ? "the tunnel's own server" : monitor.settings.destination
        return "Probes to \(target) every \(monitor.settings.intervalSeconds) s · last 5 min · \(stats.sent) probes"
    }

    private func tone(for kind: TunnelEvent.Kind) -> StatusTone {
        switch kind {
        case .connected, .handshake: return .good
        case .reconnect: return .warn
        case .disconnected: return .neutral
        case .error: return .bad
        }
    }
}
