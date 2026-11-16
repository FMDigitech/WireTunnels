import SwiftUI

/// ✓ / ✗ list used by every form that validates before saving. Each line says what is checked and
/// whether it holds, in words and an icon, so a failure is never only a colour.
struct Checklist: View {
    let items: [(ok: Bool, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.ok ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(item.ok ? Color.green : Color.secondary)
                    Text(item.text).font(.callout)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(item.ok ? "met" : "not met")
            }
        }
    }
}

/// Pairs two personal tunnels into a client-side multi-hop chain and connects/disconnects them as a
/// unit. Managed (shared) tunnels are excluded from chains for now to avoid multi-user
/// connect/disconnect races on a shared tunnel used as a hop.
struct HopChainView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var monitor: LinkQualityMonitor
    @EnvironmentObject var navigation: DashboardNavigation

    private enum ChainTab: String, CaseIterable, Identifiable {
        case overview = "Overview", settings = "Settings"
        var id: String { rawValue }
    }

    @State private var selectedID: UUID?
    @State private var tab: ChainTab = .overview
    @State private var range: ChartRange = .minutes15
    @State private var creating = false
    @State private var newHopID: UUID?
    @State private var newExitID: UUID?
    @State private var busyChainID: UUID?
    @State private var errorMessage: String?
    @State private var deleting: HopChain?

    // MARK: Lookups

    private var personalTunnels: [Tunnel] { tunnelManager.tunnels.filter { $0.scope == .personal } }

    private func tunnel(_ id: UUID) -> Tunnel? { tunnelManager.tunnels.first { $0.id == id } }

    private func isActive(_ chain: HopChain) -> Bool {
        (tunnel(chain.hopTunnelID)?.isActive ?? false) || (tunnel(chain.exitTunnelID)?.isActive ?? false)
    }

    private func isBusy(_ chain: HopChain) -> Bool {
        busyChainID == chain.id || [chain.hopTunnelID, chain.exitTunnelID].compactMap { tunnel($0) }.contains {
            let status = tunnelManager.connectionStatus(for: $0)
            return status == .connecting || status == .reconnecting
        }
    }

    private func chainName(_ chain: HopChain) -> String {
        "\(tunnel(chain.hopTunnelID)?.name ?? "Deleted tunnel") → \(tunnel(chain.exitTunnelID)?.name ?? "Deleted tunnel")"
    }

    private var selectedChain: HopChain? {
        tunnelManager.hopChains.first { $0.id == selectedID } ?? tunnelManager.hopChains.first
    }

    // MARK: Verdict

    private struct Verdict {
        let tone: StatusTone
        let label: String
        let message: String
        /// A chain worth the user's attention, with the tunnel to look at first.
        var needsAttention = false
        var inspect: UUID?
    }

    private func verdict(_ chain: HopChain) -> Verdict {
        guard let entry = tunnel(chain.hopTunnelID), let exit = tunnel(chain.exitTunnelID) else {
            return Verdict(tone: .bad, label: "Tunnel missing",
                           message: "A tunnel of this chain was deleted. Delete the chain and create it again.", needsAttention: true)
        }
        if isBusy(chain) {
            return Verdict(tone: .neutral, label: "Connecting…", message: "Bringing up the entry hop, then the exit hop.")
        }
        if !entry.isActive && !exit.isActive {
            return Verdict(tone: .neutral, label: "Disconnected", message: "Connect the chain to route traffic through both hops.")
        }
        if entry.isActive != exit.isActive {
            let down = entry.isActive ? exit : entry, up = entry.isActive ? entry : exit
            return Verdict(tone: .warn, label: "Incomplete",
                           message: "\(up.name) is up, but \(down.name) is down: traffic is not using the full chain.",
                           needsAttention: true, inspect: down.id)
        }
        guard monitor.settings.enabled else {
            return Verdict(tone: .neutral, label: "Connected", message: "Quality is not being measured because monitoring is off.")
        }
        let entryStats = monitor.stats(for: entry.id), exitStats = monitor.stats(for: exit.id)
        guard entryStats.isMeasured, exitStats.isMeasured else {
            return Verdict(tone: .neutral, label: "Collecting…", message: "Both hops are up. Collecting the first measurements.")
        }
        let limits = monitor.settings.thresholds
        let levels = [(entry, limits.level(for: entryStats)), (exit, limits.level(for: exitStats))]
        if let bad = levels.first(where: { $0.1 == .poor }) {
            return Verdict(tone: .bad, label: "Failing", message: "Needs attention: \(bad.0.name) has poor latency or packet loss. Inspect that hop first.",
                           needsAttention: true, inspect: bad.0.id)
        }
        if let mid = levels.first(where: { $0.1 == .fair }) {
            return Verdict(tone: .warn, label: "Degraded", message: "Usable, but \(mid.0.name) is slower than the Good limits. Inspect that hop first.",
                           needsAttention: true, inspect: mid.0.id)
        }
        return Verdict(tone: .good, label: "Operational",
                       message: "Traffic goes You → \(entry.name) → \(exit.name) → Internet. End-to-end \(Format.ms(exitStats.medianMs)) with \(String(format: "%.1f", exitStats.lossPercent))% packet loss.")
    }

    // MARK: Body

    var body: some View {
        Group {
            if tunnelManager.hopChains.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        banner
                        emptyState
                        newChainCard
                    }
                    .padding(20)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    banner
                    MasterDetail(masterFraction: 0.4, masterMin: 320, detailMin: 360, inset: 0) {
                        ScrollView {
                            VStack(spacing: 12) {
                                chainList
                                if creating { newChainCard }
                            }
                            .padding(8)
                        }
                    } detail: {
                        ScrollView {
                            if let chain = selectedChain { detail(chain).padding(16) }
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Multi-Hop")
        .alert("Error", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Delete this chain?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { chain in
            Button("Delete Chain", role: .destructive) { tunnelManager.removeHopChain(chain) }
            Button("Cancel", role: .cancel) {}
        } message: { chain in
            Text("\(chainName(chain)) stops being a chain. Both tunnels stay as they are.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Multi-Hop").font(.title2.bold())
                Text("Route a tunnel's traffic through another tunnel first, so the exit server sees the hop's IP instead of yours.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if !tunnelManager.hopChains.isEmpty {
                Button { creating.toggle() } label: { Label("New Chain", systemImage: "plus") }
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        let chains = tunnelManager.hopChains
        let verdicts = chains.map { ($0, verdict($0)) }
        let attention = verdicts.filter { $0.1.needsAttention }
        let connected = chains.filter { isActive($0) }
        if chains.isEmpty {
            SummaryBanner(tone: .neutral, title: "No chains yet",
                          detail: "Route one tunnel through another so the exit server sees the entry hop's IP instead of yours.")
        } else if let first = attention.first {
            SummaryBanner(tone: first.1.tone == .bad ? .bad : .warn,
                          title: "\(attention.count) chain\(attention.count == 1 ? " needs" : "s need") attention",
                          detail: "\(chainName(first.0)): \(first.1.label.lowercased())")
        } else if verdicts.contains(where: { $0.1.label == "Connecting…" }) {
            SummaryBanner(tone: .neutral, title: "A chain is connecting", detail: "Entry hop first, then the exit hop. Measurements follow in a few seconds.")
        } else if connected.isEmpty {
            SummaryBanner(tone: .neutral, title: "No chain is connected", detail: "Connect a chain to route traffic through its hops.")
        } else if !monitor.settings.enabled {
            SummaryBanner(tone: .info, title: "Quality is not being measured",
                          detail: "\(connected.count) of \(chains.count) chain\(chains.count == 1 ? " is" : "s are") connected. Turn on monitoring to see latency and loss.") {
                Button("Turn on monitoring…") { navigation.requestSidebar(.settings) }
            }
        } else {
            SummaryBanner(tone: .good, title: connected.count == chains.count ? "All chains are operational" : "Connected chains are operational",
                          detail: "\(connected.count) of \(chains.count) chain\(chains.count == 1 ? "" : "s") connected")
        }
    }

    private var emptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("No chains yet").font(.headline)
                Text("Create one below: pick a first (entry) tunnel and a last (exit) tunnel.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: List

    private var chainList: some View {
        Card(padding: 4, plain: true) {
            VStack(spacing: 0) {
                ForEach(tunnelManager.hopChains) { chain in
                    chainRow(chain)
                    if chain.id != tunnelManager.hopChains.last?.id { Divider() }
                }
            }
        }
    }

    private func chainRow(_ chain: HopChain) -> some View {
        let v = verdict(chain)
        let active = isActive(chain), busy = isBusy(chain)
        let selected = selectedChain?.id == chain.id
        return HStack(spacing: 12) {
            Button { selectedID = chain.id } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chainName(chain)).font(.callout.weight(.semibold))
                        Text("You → entry → exit → Internet").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(text: v.label, tone: v.tone)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if busy {
                ProgressView().controlSize(.small).frame(width: 90)
            } else {
                Button(active ? "Disconnect" : "Connect") { toggle(chain) }
                    .buttonStyle(.bordered)
                    .frame(width: 90)
                    .disabled(tunnelManager.isShuttingDown || (!active && !tunnelManager.canConnectTunnels))
                    .help(active ? "Disconnect this chain" : (tunnelManager.connectionUnavailableReason ?? "Connect this chain"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Detail

    private func detail(_ chain: HopChain) -> some View {
        let v = verdict(chain)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(chainName(chain)).font(.title3.weight(.semibold))
                StatusPill(text: v.label, tone: v.tone)
            }
            TabStrip(tabs: ChainTab.allCases, selection: $tab)
            Notice(tone: v.tone == .neutral ? .info : v.tone, title: v.label, message: v.message)
            if tab == .overview { overview(chain, verdict: v) } else { settings(chain) }
        }
    }

    private func overview(_ chain: HopChain, verdict v: Verdict) -> some View {
        let entry = tunnel(chain.hopTunnelID), exit = tunnel(chain.exitTunnelID)
        let measured = monitor.settings.enabled && (entry?.isActive ?? false) && (exit?.isActive ?? false)
        return VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    PaneSectionHeader(title: "Route")
                    // Left to right when there is room, top to bottom when the pane is narrow.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 8) {
                            node("You", icon: "laptopcomputer")
                            arrow("Your traffic")
                            hopCard(entry, role: "Entry · hop 1", measured: measured, verdict: v)
                            arrow("Through the entry")
                            hopCard(exit, role: "Exit · hop 2", measured: measured, verdict: v)
                            arrow("Exit → Internet")
                            node("Internet", icon: "globe")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            node("You", icon: "laptopcomputer")
                            downArrow("Your traffic")
                            hopCard(entry, role: "Entry · hop 1", measured: measured, verdict: v)
                            downArrow("Through the entry")
                            hopCard(exit, role: "Exit · hop 2", measured: measured, verdict: v)
                            downArrow("Exit → Internet")
                            node("Internet", icon: "globe")
                        }
                    }
                }
            }
            if measured, let exit {
                endToEnd(exit)
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(monitor.settings.enabled ? "No live data" : "Not measured").font(.headline)
                        Text(monitor.settings.enabled ? "Both hops must be connected before latency and loss can be measured."
                                                      : "Latency and loss need the active probes, which are off.")
                            .font(.callout).foregroundStyle(.secondary)
                        if !monitor.settings.enabled {
                            Button("Turn on monitoring…") { navigation.requestSidebar(.settings) }
                        }
                    }
                }
            }
            events(chain)
            Text("End-to-end latency is measured by its own probe through the whole chain (on the exit tunnel). It is not the sum of the hop latencies.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func node(_ title: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.semibold))
        }
        .frame(width: 70, height: 96)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func arrow(_ label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Text(label).font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .frame(width: 64, height: 96)
    }

    private func downArrow(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down").foregroundStyle(.secondary)
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.leading, 24)
    }

    @ViewBuilder
    private func hopCard(_ tunnel: Tunnel?, role: String, measured: Bool, verdict v: Verdict) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(role).font(.caption).foregroundStyle(.secondary)
            Text(tunnel?.name ?? "Deleted tunnel").font(.callout.weight(.semibold))
            if let tunnel {
                let connecting = tunnelManager.connectionStatus(for: tunnel) == .connecting
                HStack(spacing: 5) {
                    Circle().fill(tunnel.isActive ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(connecting ? "Connecting…" : tunnel.isActive ? "Online" : "Offline").font(.caption)
                }
                if measured {
                    let stats = monitor.stats(for: tunnel.id)
                    HStack(spacing: 6) {
                        QualityBadge(level: monitor.quality(for: tunnel))
                        Text(Format.ms(stats.medianMs)).font(.caption.monospacedDigit())
                    }
                    Text("loss \(String(format: "%.1f", stats.lossPercent))% (\(stats.lost) of \(stats.sent))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Inspect tunnel") { navigation.requestTunnel(tunnel.id) }.controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(v.inspect == tunnel?.id ? v.tone.color : .clear, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
    }

    private func endToEnd(_ exit: Tunnel) -> some View {
        let stats = monitor.stats(for: exit.id)
        let samples = monitor.probeSamples(for: exit.id, since: Date().addingTimeInterval(-range.seconds))
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        PaneSectionHeader(title: "End-to-end latency",
                                          note: "Active probes through the whole chain · every \(monitor.settings.intervalSeconds) s")
                        Spacer()
                        RangePicker(range: $range)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        PaneSectionHeader(title: "End-to-end latency",
                                          note: "Active probes through the whole chain · every \(monitor.settings.intervalSeconds) s")
                        RangePicker(range: $range)
                    }
                }
                LatencyChart(samples: samples, range: range)
                HStack(spacing: 16) {
                    Metric(label: "End-to-end latency", value: Format.ms(stats.medianMs),
                           note: stats.p95Ms.map { "95% under \(Format.ms($0))" })
                    Metric(label: "End-to-end loss", value: "\(String(format: "%.1f", stats.lossPercent))%",
                           note: "\(stats.lost) of \(stats.sent) probes lost")
                    Metric(label: "Last reconnect", value: lastReconnect(for: exit.id).map(Format.clock) ?? "—",
                           note: lastReconnect(for: exit.id) == nil ? "none in this session" : "automatic")
                }
            }
        }
    }

    private func lastReconnect(for id: UUID) -> Date? {
        monitor.events(for: id).first { $0.kind == .reconnect }?.time
    }

    private func events(_ chain: HopChain) -> some View {
        let ids: Set<UUID> = [chain.hopTunnelID, chain.exitTunnelID]
        let list = monitor.events.filter { ids.contains($0.tunnelID) }.prefix(8)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                PaneSectionHeader(title: "Events", note: "Seen in this session. Close in time does not mean one caused the other.")
                if list.isEmpty {
                    Text("No events yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(list)) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Format.clock(event.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                        StatusPill(text: event.kind.rawValue, tone: event.kind == .error ? .bad : event.kind == .reconnect ? .warn : .neutral, showsIcon: false)
                        Text("\(event.tunnelName) · \(event.detail)").font(.callout).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func settings(_ chain: HopChain) -> some View {
        let active = isActive(chain)
        return VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    PaneSectionHeader(title: "Chain")
                    InfoRow(label: "Entry tunnel (hop 1)", value: tunnel(chain.hopTunnelID)?.name ?? "Deleted tunnel")
                    InfoRow(label: "Exit tunnel (hop 2)", value: tunnel(chain.exitTunnelID)?.name ?? "Deleted tunnel")
                    InfoRow(label: "Created", value: chain.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("A chain's tunnels cannot be changed. To use other tunnels, delete this chain and create a new one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    PaneSectionHeader(title: "Measurement")
                    InfoRow(label: "Active probes", value: monitor.settings.enabled ? "On" : "Off")
                    InfoRow(label: "Probe target", value: monitor.settings.destination.isEmpty ? "Each tunnel's own server" : monitor.settings.destination,
                            monospaced: !monitor.settings.destination.isEmpty)
                    InfoRow(label: "Probe interval", value: "\(monitor.settings.intervalSeconds) seconds")
                    Text("Probes send a small amount of traffic. They are shared by all tunnels and set in Settings › Monitoring; without them, latency and loss are not measured.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Monitoring settings…") { navigation.requestSidebar(.settings) }
                }
            }
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete chain").font(.headline)
                        Text(active ? "Disconnect the chain first." : "The tunnels stay; only the pairing is removed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete Chain…", role: .destructive) { deleting = chain }
                        .disabled(active || isBusy(chain))
                }
            }
        }
    }

    // MARK: Actions

    private func toggle(_ chain: HopChain) {
        guard !tunnelManager.isShuttingDown, isActive(chain) || tunnelManager.canConnectTunnels else { return }
        selectedID = chain.id
        busyChainID = chain.id
        Task {
            if isActive(chain) {
                await tunnelManager.disconnectHopChain(chain)
            } else {
                await tunnelManager.connectHopChain(chain)
            }
            if let latest = tunnelManager.errorMessage {
                errorMessage = latest
                tunnelManager.errorMessage = nil
            }
            busyChainID = nil
        }
    }

    // MARK: New chain

    private var newChecks: [(ok: Bool, text: String)] {
        let hop = newHopID.flatMap(tunnel), exit = newExitID.flatMap(tunnel)
        let both = [hop, exit].compactMap { $0 }
        let inChain = both.contains { t in tunnelManager.hopChains.contains { $0.hopTunnelID == t.id || $0.exitTunnelID == t.id } }
        return [
            (hop != nil, "Entry tunnel is selected"),
            (exit != nil, "Exit tunnel is selected"),
            (newHopID == nil || newHopID != newExitID, "Entry and exit are different tunnels"),
            (both.count == 2 && both.allSatisfy { !$0.isActive }, "Both tunnels are disconnected"),
            (both.count == 2 && both.allSatisfy { $0.scope == .personal }, "Tunnels are personal (not shared)"),
            (both.count == 2 && !inChain, "Tunnels are not part of another chain"),
            (both.count == 2 && both.allSatisfy { $0.inventoryCommand == nil }, "Neither tunnel uses Inventory protection"),
        ]
    }

    private var newChainCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PaneSectionHeader(title: "New Chain",
                                      note: "Traffic goes through the entry tunnel first, then the exit tunnel, so the exit server sees the entry hop's IP instead of yours.")
                    Spacer()
                    if creating && !tunnelManager.hopChains.isEmpty {
                        Button("Close") { creating = false }
                    }
                }
                HStack(spacing: 12) {
                    Picker("Entry tunnel (first hop)", selection: $newHopID) {
                        Text("Select a tunnel…").tag(UUID?.none)
                        ForEach(personalTunnels) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Picker("Exit tunnel (last hop)", selection: $newExitID) {
                        Text("Select a tunnel…").tag(UUID?.none)
                        ForEach(personalTunnels) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                .pickerStyle(.menu)
                Checklist(items: newChecks)
                Button("Create Chain") {
                    guard let hop = newHopID, let exit = newExitID else { return }
                    tunnelManager.addHopChain(hopTunnelID: hop, exitTunnelID: exit)
                    if let latest = tunnelManager.errorMessage {
                        errorMessage = latest
                        tunnelManager.errorMessage = nil
                    } else {
                        selectedID = tunnelManager.hopChains.last?.id
                        newHopID = nil
                        newExitID = nil
                        creating = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!newChecks.allSatisfy(\.ok))
                Text("Connecting the chain brings the entry hop up first, then routes the exit tunnel's own traffic through it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
