import SwiftUI

/// Tunnel Details: one tunnel on a full-width page. Five indicators, speed and latency over time,
/// what the network and configuration are set to (each row opens its tab), and the technical facts.
struct TunnelFullDetailsView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var monitor: LinkQualityMonitor
    @EnvironmentObject var navigation: DashboardNavigation
    let tunnel: Tunnel
    var onClose: () -> Void
    var onOpenTab: (TunnelDetailTab) -> Void
    @State private var range: ChartRange = .minutes15

    private var live: Tunnel { tunnelManager.tunnels.first { $0.id == tunnel.id } ?? tunnel }
    private var isManaged: Bool { live.scope == .managed }
    private var stats: LinkQualityStats { monitor.stats(for: live.id) }
    private var since: Date { Date().addingTimeInterval(-range.seconds) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                indicators
                HStack(alignment: .top, spacing: 16) {
                    trafficCard
                    qualityCard
                }
                HStack(alignment: .top, spacing: 16) {
                    networkCard
                    configurationCard
                }
                technicalDetails
            }
            .padding(20)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onClose) {
                Label("Back to the list", systemImage: "chevron.left")
            }
            .buttonStyle(.link)
            .keyboardShortcut(.cancelAction)

            Text(live.name).font(.title2.bold())
            Text("\(live.engine.displayName)\(live.endpoint.map { " · \($0)" } ?? "")")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 6) {
                switch tunnelManager.connectionStatus(for: live) {
                case .connecting: StatusPill(text: "Connecting…", tone: .info)
                case .reconnecting: StatusPill(text: "Reconnecting…", tone: .warn)
                case .connectionLost: StatusPill(text: "Connection lost", tone: .bad)
                default: StatusPill(text: live.isActive ? "Connected" : "Not connected", tone: live.isActive ? .good : .neutral)
                }
                if live.isActive, let connectedAt = live.connectedAt {
                    Text(Format.duration(since: connectedAt)).font(.caption).foregroundStyle(.secondary)
                }
                if isManaged { StatusPill(text: "Shared for all users", tone: .info, showsIcon: false) }
            }
        }
    }

    // MARK: Five indicators

    private var indicators: some View {
        let latest = monitor.traffic[live.id]?.last
        let measured = stats.isMeasured
        return HStack(alignment: .top, spacing: 12) {
            Card { Metric(label: "Speed now",
                          value: live.isActive ? "↓ \(Format.mbps(latest?.rxMbps))" : "—",
                          note: live.isActive ? "↑ \(Format.mbps(latest?.txMbps))" : "tunnel is off") }
            Card { Metric(label: "Data this session",
                          value: "↓ \(formatBytes(live.rxBytes))",
                          note: "↑ \(formatBytes(live.txBytes)) sent") }
            Card { Metric(label: "Latency (ping)",
                          value: Format.ms(stats.medianMs),
                          note: measured ? "95% under \(Format.ms(stats.p95Ms))" : "not measured") }
            Card { Metric(label: "Packet loss",
                          value: measured ? String(format: "%.1f%%", stats.lossPercent) : "—",
                          note: measured ? "\(stats.lost) of \(stats.sent) probes" : "not measured") }
            Card { Metric(label: "Last handshake",
                          value: Format.ago(live.lastHandshake),
                          note: "key exchange") }
        }
    }

    // MARK: Charts

    private var trafficCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    PaneSectionHeader(title: "Traffic",
                                      note: "Measured on this device · \(live.isActive ? "updated \(Format.clock(Date()))" : "tunnel is off")")
                    Spacer()
                    RangePicker(range: $range)
                }
                SpeedChart(points: monitor.trafficPoints(for: live.id, since: since), range: range,
                           markers: monitor.events(for: live.id).filter { $0.kind == .reconnect }.map(\.time))
            }
        }
    }

    private var qualityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                if monitor.settings.enabled {
                    let target = monitor.settings.destination.isEmpty ? "the tunnel's own server" : monitor.settings.destination
                    PaneSectionHeader(title: "Latency and packet loss", note: "Active probes to \(target) · last \(range.rawValue)")
                    LatencyChart(samples: monitor.probeSamples(for: live.id, since: since), range: range)
                } else {
                    PaneSectionHeader(title: "Latency and packet loss", note: "Needs the optional probes")
                    Text("Latency and packet loss are measured by active probes, which are off. Speed and handshake come from the tunnel itself and are always shown.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Turn on monitoring…") { navigation.requestSidebar(.settings) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: Network and configuration

    private var networkCard: some View {
        let routes = live.allowedIPs
        let dns = WireGuardDNS.servers(live.dns)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                PaneSectionHeader(title: "Network and routing")
                InfoRow(label: "Routing", value: routes.contains("0.0.0.0/0") ? "Tunnel default (0.0.0.0/0)" : "Only the listed networks")
                InfoRow(label: "DNS", value: dns.isEmpty ? "System DNS" : "\(dns.joined(separator: ", ")) (tunnel)", monospaced: !dns.isEmpty)
                InfoRow(label: "Allowed IPs",
                        value: routes.isEmpty ? "—" : routes.prefix(6).joined(separator: ", ") + (routes.count > 6 ? " … \(routes.count) total" : ""),
                        monospaced: true)
                InfoRow(label: "Endpoint", value: live.endpoint ?? "—", monospaced: live.endpoint != nil)
                InfoRow(label: "Address", value: live.address?.joined(separator: ", ") ?? "—", monospaced: live.address != nil)
            }
        }
    }

    /// One line per setting group; each row opens the tab where it can be changed.
    private var configurationCard: some View {
        let rule = live.autoConnectRule
        let onDemand = [rule.connect.enabled ? "Connect on \(rule.connect.interface.displayName)" : nil,
                        rule.disconnect.enabled ? "Disconnect rule on" : nil].compactMap { $0 }
        let rows: [(TunnelDetailTab, String, String)] = [
            isManaged ? nil : (.network, "Inventory", live.inventoryCommand == nil
                               ? "Not configured" : "Command saved · \(live.inventoryAllowedIPs.count) prefixes cached"),
            (.onDemand, "On-Demand", onDemand.isEmpty ? "Off (no connect or disconnect rules)" : onDemand.joined(separator: " · ")),
            (.safety, "Security", "Kill switch \(live.killSwitchEnabled ? "on" : "off") · leak warning \(live.ipFamilyLeakWarningAcknowledged ? "silenced" : "on")"),
            (.network, "Split DNS", live.splitDNSDomains.isEmpty ? "Not configured (system DNS for all domains)" : live.splitDNSDomains.joined(separator: ", ")),
            (.network, "Split tunnel", live.excludedRoutes.isEmpty ? "No exclusions"
                : "\(live.excludedRoutes.count) exclusion\(live.excludedRoutes.count == 1 ? "" : "s")")
        ].compactMap { $0 }
        return Card {
            VStack(alignment: .leading, spacing: 4) {
                PaneSectionHeader(title: "Configuration", note: "Select a row to change it.")
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Button { onOpenTab(row.0) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(row.1).font(.callout.weight(.semibold)).frame(width: 100, alignment: .leading)
                            Text(row.2).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.1): \(row.2). Opens the \(row.0.rawValue) tab.")
                    Divider()
                }
            }
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Interface", value: live.interfaceName ?? "—", monospaced: true)
                InfoRow(label: "Peer public key", value: live.publicKey ?? "—", monospaced: true)
                InfoRow(label: "Your public key", value: live.localPublicKey ?? "—", monospaced: true)
                InfoRow(label: "Received", value: formatBytes(live.rxBytes))
                InfoRow(label: "Sent", value: formatBytes(live.txBytes))
                InfoRow(label: "Config file", value: live.configPath, monospaced: true)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text("Technical details").font(.headline)
                Text("· interface, keys, counters").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}
