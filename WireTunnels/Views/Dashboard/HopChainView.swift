import SwiftUI

/// Lets a user pair two personal tunnels into a client-side multi-hop chain and
/// connect/disconnect them as a unit. Managed (shared) tunnels are excluded from
/// chains for now to avoid multi-user connect/disconnect races on a shared tunnel
/// used as a hop.
struct HopChainView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @State private var newHopID: UUID?
    @State private var newExitID: UUID?
    @State private var busyChainID: UUID?
    @State private var errorMessage: String?

    private var personalTunnels: [Tunnel] {
        tunnelManager.tunnels.filter { $0.scope == .personal }
    }

    private func tunnel(_ id: UUID) -> Tunnel? {
        tunnelManager.tunnels.first { $0.id == id }
    }

    private func isActive(_ chain: HopChain) -> Bool {
        (tunnel(chain.hopTunnelID)?.isActive ?? false) || (tunnel(chain.exitTunnelID)?.isActive ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Multi-Hop")
                        .font(.title2.bold())
                    Text("Route a tunnel's traffic through another tunnel first, so the exit server sees the hop's IP instead of yours.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !tunnelManager.hopChains.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(tunnelManager.hopChains) { chain in
                            chainRow(chain)
                        }
                    }
                }

                Divider()

                newChainForm
            }
            .padding(20)
        }
        .navigationTitle("Multi-Hop")
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func chainRow(_ chain: HopChain) -> some View {
        let hopName = tunnel(chain.hopTunnelID)?.name ?? "Deleted tunnel"
        let exitName = tunnel(chain.exitTunnelID)?.name ?? "Deleted tunnel"
        let active = isActive(chain)
        let busy = busyChainID == chain.id || [chain.hopTunnelID, chain.exitTunnelID]
            .compactMap { tunnel($0) }
            .contains {
                let status = tunnelManager.connectionStatus(for: $0)
                return status == .connecting || status == .reconnecting
            }

        return HStack(spacing: 12) {
            Circle()
                .fill(active ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)

            HStack(spacing: 6) {
                Text(hopName).font(.subheadline.weight(.medium))
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(exitName).font(.subheadline.weight(.medium))
            }

            Spacer()

            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(active ? "Disconnect" : "Connect") {
                    toggle(chain)
                }
                .buttonStyle(.bordered)
                .disabled(tunnelManager.isShuttingDown || (!active && !tunnelManager.canConnectTunnels))
                .help(active ? "Disconnect this chain" : (tunnelManager.connectionUnavailableReason ?? "Connect this chain"))
            }

            Button {
                tunnelManager.removeHopChain(chain)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(active || busy)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func toggle(_ chain: HopChain) {
        guard !tunnelManager.isShuttingDown,
              isActive(chain) || tunnelManager.canConnectTunnels else { return }
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

    private var newChainForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Chain").font(.headline)

            HStack(spacing: 12) {
                Picker("Hop", selection: $newHopID) {
                    Text("Choose a tunnel").tag(UUID?.none)
                    ForEach(personalTunnels) { tunnel in
                        Text(tunnel.name).tag(Optional(tunnel.id))
                    }
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("Exit", selection: $newExitID) {
                    Text("Choose a tunnel").tag(UUID?.none)
                    ForEach(personalTunnels) { tunnel in
                        Text(tunnel.name).tag(Optional(tunnel.id))
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Button("Add Chain") {
                guard let hop = newHopID, let exit = newExitID else { return }
                tunnelManager.addHopChain(hopTunnelID: hop, exitTunnelID: exit)
                if let latest = tunnelManager.errorMessage {
                    errorMessage = latest
                    tunnelManager.errorMessage = nil
                } else {
                    newHopID = nil
                    newExitID = nil
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(newHopID == nil || newExitID == nil || newHopID == newExitID)

            Text("Both tunnels must be disconnected and personal (not shared). Connecting the chain brings the hop up first, then routes the exit tunnel's own traffic through it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
