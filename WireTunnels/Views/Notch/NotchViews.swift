import SwiftUI

/// A traffic rate in bytes per second shown in Mbps, like everywhere else in the app.
private func mbps(_ bytesPerSecond: Double) -> String { Format.mbps(bytesPerSecond * 8 / 1_000_000) }

private func color(for level: QualityLevel) -> Color {
    switch level {
    case .good: return .green
    case .fair: return .orange
    case .poor: return .red
    case .unmeasured: return .secondary
    }
}

/// Left of the notch: connection status and how many tunnels are up.
struct NotchLeadingView: View {
    @ObservedObject var tunnelManager: TunnelManager

    var body: some View {
        // Yellow only for a warning or a problem; a note (e.g. different DNS servers) stays green.
        let warning = tunnelManager.hasAttentionWarnings
        HStack(spacing: 4) {
            Image(systemName: warning ? "exclamationmark.shield.fill" : "lock.shield.fill")
                .foregroundStyle(warning ? Color.yellow : Color.green)
            Text("\(tunnelManager.tunnels.filter(\.isActive).count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(warning ? "VPN connected with warnings" : "VPN connected")
    }
}

/// Right of the notch: combined speed. Empty when statistics are off.
struct NotchTrailingView: View {
    @ObservedObject var tunnelManager: TunnelManager
    @AppStorage("notchShowStats") private var showStats = true

    var body: some View {
        if showStats {
            // The same total as the dashboard: a chain's exit leg is not counted twice.
            let rates = tunnelManager.totalSpeedMbps
            VStack(alignment: .trailing, spacing: 0) {
                Text("↓ \(Format.mbps(rates?.down))")
                Text("↑ \(Format.mbps(rates?.up))")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.trailing, 4)
        }
    }
}

/// Below the notch while the pointer is on it: every active tunnel, with its graph and speed.
struct NotchExpandedView: View {
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var profiles: NetworkProfileManager
    @ObservedObject var monitor: LinkQualityMonitor
    @AppStorage("notchShowStats") private var showStats = true

    init(tunnelManager: TunnelManager) {
        self.tunnelManager = tunnelManager
        profiles = tunnelManager.networkProfiles
        monitor = tunnelManager.monitor
    }

    private var activeProfileName: String? {
        profiles.profiles.first { $0.id == profiles.activeProfileID }?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WireTunnels").font(.caption.bold())
                Spacer()
                if let name = activeProfileName {
                    Label(name, systemImage: "wifi").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            ForEach(tunnelManager.tunnels.filter(\.isActive)) { tunnel in
                row(tunnel)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(minWidth: 300)
    }

    private func row(_ tunnel: Tunnel) -> some View {
        let samples = tunnelManager.trafficHistory[tunnel.id] ?? []
        return HStack(spacing: 8) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text(tunnel.name).font(.caption).lineLimit(1)
            // Quality only when the optional probes have measured it; never a guess.
            let level = monitor.quality(for: tunnel)
            if level != .unmeasured {
                Text(level.rawValue).font(.system(size: 9, weight: .semibold)).foregroundStyle(color(for: level))
            }
            Spacer(minLength: 12)
            if showStats {
                NotchSparkline(values: samples.map(\.rxRate), color: .green).frame(width: 44, height: 14)
                NotchSparkline(values: samples.map(\.txRate), color: .blue).frame(width: 44, height: 14)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("↓ \(mbps(samples.last?.rxRate ?? 0))").foregroundStyle(.green)
                    Text("↑ \(mbps(samples.last?.txRate ?? 0))").foregroundStyle(.blue)
                }
                .font(.system(size: 9, design: .monospaced))
            }
        }
    }
}

/// A line graph of recent samples, scaled to its own peak.
private struct NotchSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let peak = max(values.max() ?? 0, 1)
            Path { path in
                for (index, value) in values.enumerated() {
                    let x = values.count > 1 ? geometry.size.width * CGFloat(index) / CGFloat(values.count - 1) : 0
                    let point = CGPoint(x: x, y: geometry.size.height * (1 - CGFloat(value / peak)))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(color, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
