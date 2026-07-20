import SwiftUI

struct TunnelListView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    let filter: SidebarItem
    @Binding var selectedTunnel: Tunnel?

    private var filteredTunnels: [Tunnel] {
        switch filter {
        case .all:
            return tunnelManager.tunnels
        case .active:
            return tunnelManager.tunnels.filter { $0.isActive }
        case .shared:
            return tunnelManager.sharedTunnels
        case .favorites:
            return tunnelManager.favoriteTunnels
        case .warnings:
            // Show tunnels referenced in any warning
            let warnedNames = tunnelManager.activeWarnings.flatMap { warning -> [String] in
                switch warning {
                case .multipleFullTunnels(let names):   return names
                case .fullTunnelActive(let name):       return [name]
                case .overlappingAllowedIPs(let a, let b): return [a, b]
                case .conflictingDNS(let names):        return names
                case .killSwitchBlocking(let name):     return [name]
                }
            }
            let warnedSet = Set(warnedNames)
            return tunnelManager.tunnels.filter { warnedSet.contains($0.name) }
        case .settings, .log:
            return []
        }
    }

    private var emptyStateTitle: String {
        switch filter {
        case .all:       return "No Tunnels"
        case .active:    return "No Active Tunnels"
        case .shared:    return "No Shared Tunnels"
        case .favorites: return "No Favorites"
        case .warnings:  return "No Warnings"
        case .settings, .log: return ""
        }
    }

    private var emptyStateMessage: String {
        switch filter {
        case .all:
            return "Import a .conf file or create a new tunnel to get started."
        case .active:
            return "Connect a tunnel to see it here."
        case .shared:
            return "Make a tunnel shared to show it to all users on this Mac."
        case .favorites:
            return "Star a tunnel to mark it as a favorite."
        case .warnings:
            return "Your configuration looks good — no issues detected."
        case .settings, .log:
            return ""
        }
    }

    private var emptyStateIcon: String {
        switch filter {
        case .all:       return "network"
        case .active:    return "bolt.slash"
        case .shared:    return "person.2"
        case .favorites: return "star"
        case .warnings:  return "checkmark.shield"
        case .settings, .log: return "gear"
        }
    }

    var body: some View {
        Group {
            if tunnelManager.isLoading && tunnelManager.tunnels.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading tunnels…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredTunnels.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: emptyStateIcon)
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(emptyStateTitle)
                        .font(.headline)
                    Text(emptyStateMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredTunnels, selection: $selectedTunnel) { tunnel in
                    TunnelRowView(tunnel: tunnel)
                        .environmentObject(tunnelManager)
                        .tag(tunnel)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(filter.rawValue)
        .navigationSubtitle(subtitleText)
        .task {
            guard tunnelManager.isInitialized else { return }
            await tunnelManager.refreshStatus()
        }
    }

    private var subtitleText: String {
        let count = filteredTunnels.count
        switch filter {
        case .all:
            let active = tunnelManager.activeTunnelCount
            return "\(count) tunnel\(count == 1 ? "" : "s"), \(active) active"
        case .active:
            return "\(count) connected"
        case .shared:
            return "\(count) shared"
        case .favorites:
            return "\(count) favorite\(count == 1 ? "" : "s")"
        case .warnings:
            return "\(count) tunnel\(count == 1 ? "" : "s") affected"
        case .settings, .log:
            return ""
        }
    }
}
