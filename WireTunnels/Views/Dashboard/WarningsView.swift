import SwiftUI

/// One row of the Warnings screen. Configuration items come from the app's own checks;
/// degradation items come from the optional probes and are only a measurement, not a cause.
private struct WarningItem: Identifiable {
    enum Kind: String { case configuration = "Configuration", degradation = "Degradation" }

    let id: String
    let kind: Kind
    let severity: WarningSeverity
    let title: String
    let affects: [String]
    let message: String
    let evidence: [(label: String, value: String)]
    let nextStep: String
    let actionLabel: String
    let target: SidebarItem

    var tone: StatusTone {
        switch severity {
        case .info: return .info
        case .warning: return .warn
        case .error: return .bad
        }
    }

    var severityLabel: String {
        switch severity {
        case .info: return "Note"
        case .warning: return "Warning"
        case .error: return "Problem"
        }
    }
}

struct WarningsView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var monitor: LinkQualityMonitor
    @EnvironmentObject var navigation: DashboardNavigation
    @State private var selectedID: String?
    @State private var search = ""
    @State private var typeFilter = "All warnings"

    private func dnsEvidence(_ names: [String]) -> [(label: String, value: String)] {
        names.map { name in
            let dns = tunnelManager.tunnels.first { $0.name == name }.map { WireGuardDNS.servers($0.dns).joined(separator: ", ") } ?? "—"
            return (name, dns.isEmpty ? "—" : dns)
        }
    }

    private var items: [WarningItem] {
        var list: [WarningItem] = tunnelManager.activeWarnings.map { warning in
            let affects: [String]
            let evidence: [(label: String, value: String)]
            let next: (String, String, SidebarItem)
            switch warning {
            case .multipleFullTunnels(let names):
                affects = names; evidence = names.map { ($0, "AllowedIPs 0.0.0.0/0") }
                next = ("Keep one full tunnel connected, or change a tunnel to split routing.", "Open Network Doctor", .doctor)
            case .overlappingAllowedIPs(let a, let b):
                affects = [a, b]
                let shared = Set(tunnelManager.tunnels.first { $0.name == a }?.allowedIPs ?? [])
                    .intersection(tunnelManager.tunnels.first { $0.name == b }?.allowedIPs ?? [])
                evidence = [("Shared ranges", shared.sorted().joined(separator: ", "))]
                next = ("Narrow AllowedIPs on one tunnel so each range has one owner.", "Open All Tunnels", .all)
            case .conflictingDNS(let names):
                affects = names; evidence = dnsEvidence(names)
                next = ("Review the tunnel settings, then check again in Network Doctor.", "Open Network Profiles", .profiles)
            case .killSwitchBlocking(let name):
                affects = [name]; evidence = [(name, "Kill switch is blocking non-tunnel traffic")]
                next = ("Reconnect the tunnel, or turn its kill switch off in the Safety tab.", "Open All Tunnels", .all)
            case .ipFamilyLeak(let name, let leak):
                affects = [name]; evidence = [(name, leak.problem)]
                next = ("Use the fix offered in the menu bar menu, or acknowledge single-family routing in the Safety tab.", "Open All Tunnels", .all)
            case .noHandshake(let name, _):
                let t = tunnelManager.tunnels.first { $0.name == name }
                affects = [name]
                evidence = [("Received", t.map { formatBytes($0.rxBytes) } ?? "—"), ("Sent", t.map { formatBytes($0.txBytes) } ?? "—"),
                            ("Connected for", t?.connectedAt.map { Format.duration(since: $0) } ?? "—")]
                next = ("Check endpoint, keys and that UDP is allowed, then read the log.", "Open Log", .log)
            }
            return WarningItem(id: warning.id, kind: .configuration, severity: warning.severity, title: warning.title,
                               affects: affects, message: warning.message, evidence: evidence,
                               nextStep: next.0, actionLabel: next.1, target: next.2)
        }
        if monitor.settings.enabled {
            let t = monitor.settings.thresholds
            for tunnel in tunnelManager.tunnels where tunnel.isActive {
                let level = monitor.quality(for: tunnel)
                guard level == .fair || level == .poor else { continue }
                let s = monitor.stats(for: tunnel.id)
                list.append(WarningItem(
                    id: "degradation-\(tunnel.id)", kind: .degradation, severity: level == .poor ? .error : .warning,
                    title: "\(level.rawValue) connection quality", affects: [tunnel.name],
                    message: "Over the last 5 minutes the probes saw latency or packet loss above the \(level == .poor ? "Poor" : "Fair") limit. This is a measurement; it does not say why.",
                    evidence: [("Rule", "Median ≥ \(Int(level == .poor ? t.poorPingMs : t.fairPingMs)) ms or loss ≥ \(Int(level == .poor ? t.poorLossPercent : t.fairLossPercent))%"),
                               ("Window", "Last 5 min · \(s.sent) probes"),
                               ("Latency (median)", Format.ms(s.medianMs)),
                               ("Packet loss", "\(s.lost) of \(s.sent) probes lost")],
                    nextStep: "Run a scan in Network Doctor and compare the time with the Log.",
                    actionLabel: "Open Network Doctor", target: .doctor))
            }
        }
        return list.sorted { rank($0.severity) > rank($1.severity) }
    }

    private func rank(_ s: WarningSeverity) -> Int { s == .error ? 2 : (s == .warning ? 1 : 0) }

    private var visible: [WarningItem] {
        items.filter { item in
            (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.affects.contains { $0.localizedCaseInsensitiveContains(search) })
            && (typeFilter == "All warnings" || item.kind.rawValue == typeFilter)
        }
    }

    var body: some View {
        let all = items
        let configCount = all.filter { $0.kind == .configuration }.count
        let degradeCount = all.filter { $0.kind == .degradation }.count
        let worst = all.map(\.severity).max { rank($0) < rank($1) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration issues and measured network degradation that need attention. They are kept apart because they have different causes.")
                .font(.callout).foregroundStyle(.secondary)
            SummaryBanner(tone: all.isEmpty ? .good : (worst == .info ? .info : (worst == .error ? .bad : .warn)),
                          title: all.isEmpty ? "No warnings" : "\(all.count) \(all.count == 1 ? "item" : "items")\(worst == .info ? ", nothing urgent" : " need attention")",
                          detail: all.isEmpty ? "Your tunnel configuration looks good." : Array(Set(all.flatMap(\.affects))).sorted().joined(separator: ", ")) {
                HStack(spacing: 8) {
                    StatusPill(text: "Configuration \(configCount)", tone: configCount == 0 ? .good : .warn, showsIcon: false)
                    StatusPill(text: monitor.settings.enabled ? "Degradation \(degradeCount)" : "Degradation not measured",
                               tone: monitor.settings.enabled ? (degradeCount == 0 ? .good : .warn) : .neutral, showsIcon: false)
                }
            }
            if !monitor.settings.enabled {
                Notice(tone: .neutral, title: "Degradation is not measured",
                       message: "Measured degradation needs the optional probes. Without them this screen only shows configuration checks, so “no warnings” does not mean the connection is healthy.")
            }
            MasterDetail(inset: 0) {
                list
            } detail: {
                detail
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Warnings")
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search warnings", text: $search).textFieldStyle(.roundedBorder)
                Picker("Type", selection: $typeFilter) {
                    ForEach(["All warnings", "Configuration", "Degradation"], id: \.self) { Text($0) }
                }.labelsHidden().fixedSize()
            }.padding(8)
            Divider()
            if visible.isEmpty {
                EmptyPane(icon: "checkmark.shield", title: "Nothing to show",
                          message: items.isEmpty ? "No warnings right now." : "No warning matches the search and filter.")
            } else {
                List(visible, selection: $selectedID) { item in
                    HStack(spacing: 8) {
                        StatusPill(text: item.severityLabel, tone: item.tone)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout.weight(.semibold))
                            Text(item.affects.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(item.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var detail: some View {
        if let item = items.first(where: { $0.id == selectedID }) ?? visible.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        StatusPill(text: item.severityLabel, tone: item.tone)
                        StatusPill(text: item.kind.rawValue, tone: .neutral, showsIcon: false)
                    }
                    Text(item.title).font(.title2.bold())
                    Text("Affects \(item.affects.joined(separator: ", "))").font(.callout).foregroundStyle(.secondary)
                    PaneSectionHeader(title: "What is happening")
                    Text(item.message).font(.callout)
                    PaneSectionHeader(title: "Evidence")
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, row in
                                InfoRow(label: row.label, value: row.value, monospaced: true)
                            }
                        }
                    }
                    PaneSectionHeader(title: "Next action")
                    Text(item.nextStep).font(.callout)
                    Button(item.actionLabel) { navigation.requestSidebar(item.target) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyPane(icon: "checkmark.shield.fill", title: "No warnings", message: "Your tunnel configuration looks good.")
        }
    }
}
