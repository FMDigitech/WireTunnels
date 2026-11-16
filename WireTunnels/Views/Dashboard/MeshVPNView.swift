import SwiftUI

/// Status and basic controls for the Tailscale and NetBird apps installed on this Mac. WireTunnels
/// talks to their command line as you; it never sees their keys. A Headscale network is reached
/// with the Tailscale client, so it shows up here as Tailscale.
struct MeshVPNView: View {
    @ObservedObject var manager: MeshVPNManager
    @EnvironmentObject var tunnelManager: TunnelManager

    private struct PendingExitNode: Identifiable {
        let node: MeshExitNode?
        var id: String { node?.id ?? "none" }
    }

    private enum ClientTab: String, CaseIterable, Identifiable {
        case overview = "Overview", peers = "Peers", exitNode = "Exit node"
        var id: String { rawValue }
    }

    @State private var pendingExitNode: PendingExitNode?
    @State private var selectedKind: MeshVPNKind?
    @State private var tab: ClientTab = .overview

    private var hasFullTunnel: Bool {
        tunnelManager.tunnels.contains { $0.isActive && $0.allowedIPs.contains { $0 == "0.0.0.0/0" || $0 == "::/0" } }
    }

    private var installed: [MeshVPNKind] {
        MeshVPNKind.allCases.filter { manager.outcomes[$0] != .notInstalled }
    }

    private func tone(_ state: MeshVPNState) -> StatusTone {
        switch state {
        case .running: return .good
        case .needsLogin, .needsApproval: return .warn
        default: return .neutral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Mesh VPNs").font(.title2.bold())
                Text("Shows and switches the Tailscale and NetBird apps installed on this Mac. They keep their own accounts and keys; WireTunnels only runs their command line as you. A Headscale network is controlled through the Tailscale client.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            if !manager.hasLoaded {
                ProgressView("Reading…").frame(maxWidth: .infinity, minHeight: 160)
            } else if installed.isEmpty {
                SummaryBanner(tone: .neutral, title: "No client installed", detail: "Tailscale and NetBird were not found.")
                EmptyPane(icon: "point.3.connected.trianglepath.dotted", title: "Tailscale and NetBird were not found",
                          message: "Install one of them and it will appear here.")
            } else {
                banner(installed)
                MasterDetail(masterFraction: 0.4, masterMin: 320, detailMin: 360, inset: 0) {
                    List(selection: $selectedKind) {
                        ForEach(installed) { kind in
                            clientRow(kind).tag(kind)
                        }
                    }
                    .scrollContentBackground(.hidden)
                } detail: {
                    ScrollView {
                        if let kind = installed.first(where: { $0 == selectedKind }) ?? installed.first {
                            detail(for: kind).padding(16)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            while !Task.isCancelled {
                await manager.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .confirmationDialog(
            "Route all traffic through an exit node?",
            isPresented: Binding(get: { pendingExitNode != nil }, set: { if !$0 { pendingExitNode = nil } }),
            presenting: pendingExitNode
        ) { pending in
            Button("Use \(pending.node?.name ?? "no exit node")") {
                Task { await manager.setExitNode(pending.node) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("A WireTunnels tunnel that routes all traffic is connected. Both would claim the default route, and the one that connected last usually wins. The Network Doctor shows which.")
        }
    }

    // MARK: Banner

    @ViewBuilder
    private func banner(_ installed: [MeshVPNKind]) -> some View {
        let statuses: [MeshVPNStatus] = installed.compactMap {
            if case .status(let status)? = manager.outcomes[$0] { return status }
            return nil
        }
        let attention = statuses.filter { !$0.health.isEmpty || $0.state == .needsLogin || $0.state == .needsApproval }
        let running = statuses.filter { $0.state == .running }
        if let first = attention.first {
            SummaryBanner(tone: .warn, title: "\(first.kind.displayName) \(first.state == .running ? "reports a problem" : first.state.label.lowercased())",
                          detail: first.state == .running ? (first.health.first ?? "") : "Finish this in the \(first.kind.displayName) app; it cannot be done from here.")
        } else if running.isEmpty {
            SummaryBanner(tone: .neutral, title: "No mesh VPN is on", detail: "Turn one on below. Account and keys stay in its own app.")
        } else {
            let peers = running.compactMap(\.peersOnline).reduce(0, +)
            SummaryBanner(tone: .good, title: running.map { $0.kind.displayName }.joined(separator: " and ") + " connected",
                          detail: "\(peers) peer\(peers == 1 ? "" : "s") online")
        }
    }

    // MARK: List

    private func powerToggle(_ kind: MeshVPNKind, _ status: MeshVPNStatus) -> some View {
        Toggle("\(kind.displayName) on", isOn: Binding(
            get: { status.state == .running },
            set: { value in Task { await manager.setEnabled(kind, value) } }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!status.state.canToggle || manager.busy.contains(kind))
    }

    private func clientRow(_ kind: MeshVPNKind) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.displayName).font(.headline)
                if case .status(let status)? = manager.outcomes[kind] {
                    FlowLayout(spacing: 6) {
                        StatusPill(text: status.state.label, tone: tone(status.state))
                        if let total = status.peersTotal {
                            Text("\(status.peersOnline ?? 0) of \(total) online").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let name = status.deviceName { Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                } else {
                    Text("Could not read its status").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if case .status(let status)? = manager.outcomes[kind] {
                if manager.busy.contains(kind) || status.state == .starting { ProgressView().controlSize(.small) }
                powerToggle(kind, status)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Detail

    private func detail(for kind: MeshVPNKind) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(kind.displayName).font(.title3.weight(.semibold))
                if case .status(let status)? = manager.outcomes[kind] {
                    StatusPill(text: status.state.label, tone: tone(status.state))
                    Spacer()
                    if manager.busy.contains(kind) || status.state == .starting { ProgressView().controlSize(.small) }
                    powerToggle(kind, status)
                } else {
                    Spacer()
                }
            }
            switch manager.outcomes[kind] {
            case .status(let status):
                tabs(for: status)
            case .failed(let message):
                Notice(tone: .warn, title: "Could not read \(kind.displayName)", message: message)
            default:
                EmptyView()
            }
            if let error = manager.actionErrors[kind] {
                Notice(tone: .bad, title: "The last change did not work", message: error)
            }
        }
    }

    @ViewBuilder
    private func tabs(for status: MeshVPNStatus) -> some View {
        let available = ClientTab.allCases.filter { $0 != .exitNode || status.kind.supportsExitNodes }
        let current = available.contains(tab) ? tab : .overview
        TabStrip(tabs: available, selection: $tab)
        switch current {
        case .overview: overview(status)
        case .peers: peers(status)
        case .exitNode: exitNode(status)
        }
    }

    @ViewBuilder
    private func overview(_ status: MeshVPNStatus) -> some View {
        // The summary figures first: how many peers, and how many reach this Mac directly or via a relay.
        if let total = status.peersTotal {
            let direct = status.peers.filter { $0.online && $0.path == .direct }.count
            let relay = status.peers.filter { $0.online && $0.path == .relay }.count
            MetricGrid(minimum: 110) {
                Metric(label: "Peers online", value: "\(status.peersOnline ?? 0) of \(total)", note: "reported by \(status.kind.displayName)")
                if status.peers.contains(where: { $0.path != nil }) {
                    Metric(label: "Direct", value: "\(direct)", note: "peer-to-peer")
                    Metric(label: "Relay", value: "\(relay)", note: "through a relay")
                }
                if status.kind.supportsExitNodes {
                    Metric(label: "Exit node", value: status.activeExitNode?.name ?? "None", note: "chosen in the Exit node tab")
                }
            }
        }
        PaneSectionHeader(title: "This device")
        if let name = status.deviceName { InfoRow(label: "Name", value: name) }
        if !status.addresses.isEmpty { InfoRow(label: "Address", value: status.addresses.joined(separator: ", "), monospaced: true) }
        if let network = status.networkName { InfoRow(label: "Network", value: network) }
        if !status.state.canToggle {
            switch status.state {
            case .needsLogin:
                Notice(tone: .warn, title: "Needs login", message: "Sign in in the \(status.kind.displayName) app; it cannot be done from here.")
            case .needsApproval:
                Notice(tone: .warn, title: "Waiting for approval",
                       message: "An administrator of the network must approve this device. Do it in the \(status.kind.displayName) admin console.")
            case .starting:
                Notice(tone: .info, title: "Starting…", message: "\(status.kind.displayName) is changing state. This can take a few seconds.")
            default:
                Notice(tone: .info, title: status.state.label, message: "\(status.kind.displayName) is in a state this app does not control.")
            }
        }
        ForEach(status.health, id: \.self) { message in
            Notice(tone: .warn, title: "\(status.kind.displayName) reports a problem", message: message)
        }
        PaneSectionHeader(title: "Account and keys")
        Text("They stay in the \(status.kind.displayName) app. WireTunnels only runs its command line as you: logging in, approvals and keys happen there.")
            .font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func peers(_ status: MeshVPNStatus) -> some View {
        if status.state == .running, !status.peers.isEmpty {
            let sorted = status.peers.sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
            PaneSectionHeader(title: "Peers", note: "Direct / Relay is what \(status.kind.displayName) itself reports. WireTunnels cannot force a direct path.")
            ForEach(sorted) { peer in
                FlowLayout(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(peer.online ? Color.green : Color.secondary).frame(width: 8, height: 8)
                        Text(peer.name).font(.callout.weight(.semibold))
                    }
                    if let address = peer.address { Text(address).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if let path = peer.path {
                        StatusPill(text: "\(path.rawValue) · client-reported", tone: path == .direct ? .good : .warn)
                    } else {
                        Text(peer.online ? "Path unknown" : "Offline").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            Text(status.state == .running ? "No peers reported." : "Peers appear when \(status.kind.displayName) is on.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func exitNode(_ status: MeshVPNStatus) -> some View {
        if status.state == .running {
            exitNodePicker(status)
        } else {
            Text("Turn \(status.kind.displayName) on to choose an exit node.").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func exitNodePicker(_ status: MeshVPNStatus) -> some View {
        HStack {
            Text("Exit node").foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Menu(status.activeExitNode?.name ?? "None") {
                Button("None") { choose(nil, current: status) }
                ForEach(status.exitNodes) { node in
                    Button(node.online ? node.name : "\(node.name) (offline)") { choose(node, current: status) }
                        .disabled(!node.online)
                }
            }
            .disabled(manager.busy.contains(.tailscale) || status.exitNodes.isEmpty)
            .fixedSize()
            Spacer()
        }
        .font(.callout)
        if status.exitNodes.isEmpty {
            Text("No device in this network offers one.").font(.caption).foregroundStyle(.tertiary)
        }
        if status.activeExitNode != nil && hasFullTunnel {
            Notice(tone: .warn, title: "Two catch-all routes",
                   message: "A WireTunnels tunnel also routes all traffic. Check the Network Doctor.")
        }
    }

    private func choose(_ node: MeshExitNode?, current status: MeshVPNStatus) {
        guard node?.id != status.activeExitNode?.id else { return }
        // Asking only when it can collide: turning an exit node off, or using one while no tunnel
        // of ours routes everything, needs no confirmation.
        if node != nil && hasFullTunnel {
            pendingExitNode = PendingExitNode(node: node)
        } else {
            Task { await manager.setExitNode(node) }
        }
    }
}
