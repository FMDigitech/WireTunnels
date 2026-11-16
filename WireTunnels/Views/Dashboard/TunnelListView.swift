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
                case .overlappingAllowedIPs(let a, let b): return [a, b]
                case .conflictingDNS(let names):        return names
                case .killSwitchBlocking(let name):     return [name]
                case .ipFamilyLeak(let name, _):        return [name]
                case .noHandshake(let name, _):         return [name]
                }
            }
            let warnedSet = Set(warnedNames)
            return tunnelManager.tunnels.filter { warnedSet.contains($0.name) }
        case .multiHop, .profiles, .doctor, .mesh, .devTools, .settings, .log:
            return []
        }
    }

    private enum StateFilter: String, CaseIterable, Identifiable {
        case all = "All states", connected = "Connected", notConnected = "Not connected"
        var id: String { rawValue }
    }

    private enum Sort: String, CaseIterable, Identifiable {
        case name = "Name", longest = "Longest connected", speed = "Speed"
        var id: String { rawValue }
    }

    @State private var search = ""
    @State private var stateFilter: StateFilter = .all
    @State private var sort: Sort = .name
    @State private var signedInCount: Int?
    @Environment(\.masterIsCompact) private var compact

    private var visibleTunnels: [Tunnel] {
        var list = filteredTunnels.filter { tunnel in
            (search.isEmpty || tunnel.name.localizedCaseInsensitiveContains(search)
                || (tunnel.endpoint ?? "").localizedCaseInsensitiveContains(search))
            && (stateFilter == .all || (stateFilter == .connected) == tunnel.isActive)
        }
        switch sort {
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .longest: list.sort { ($0.connectedAt ?? .distantFuture) < ($1.connectedAt ?? .distantFuture) }
        case .speed:
            func total(_ t: Tunnel) -> Double { tunnelManager.trafficHistory[t.id]?.last.map { $0.rxRate + $0.txRate } ?? 0 }
            list.sort { total($0) > total($1) }
        }
        return list
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search tunnels", text: $search).textFieldStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(minWidth: 140)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private var filterPickers: some View {
        HStack(spacing: 8) {
            Picker("State", selection: $stateFilter) {
                ForEach(StateFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            if filter == .active {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text("Sort: \($0.rawValue)").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    /// Search and filters share a row when there is room; otherwise the filters go below.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { searchField; filterPickers }
            VStack(alignment: .leading, spacing: 8) { searchField; filterPickers }
        }
        .padding(10)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Tunnel").frame(maxWidth: .infinity, alignment: .leading)
            Text("State").frame(width: TunnelColumns.state, alignment: .leading)
            if filter == .active && !compact {
                Text("Connected for").frame(width: TunnelColumns.session, alignment: .leading)
                Text("Last handshake").frame(width: TunnelColumns.session + 14, alignment: .leading)
            }
            Text("Speed ↓ / ↑").frame(width: TunnelColumns.speed, alignment: .leading)
            Text("Quality").frame(width: TunnelColumns.quality, alignment: .leading)
            if filter == .favorites {
                Color.clear.frame(width: TunnelColumns.action + 18, height: 1)
            } else if !compact && filter != .active {
                Color.clear.frame(width: 40, height: 1)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .padding(.horizontal, 22)
        .padding(.vertical, 6)
    }

    private var emptyStateTitle: String {
        switch filter {
        case .all:       return "No Tunnels"
        case .active:    return "No Active Tunnels"
        case .shared:    return "No Shared Tunnels"
        case .favorites: return "No Favorites"
        case .warnings:  return "No Warnings"
        case .multiHop, .profiles, .doctor, .mesh, .devTools, .settings, .log: return ""
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
        case .multiHop, .profiles, .doctor, .mesh, .devTools, .settings, .log:
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
        case .multiHop, .profiles, .doctor, .mesh, .devTools, .settings, .log: return "gear"
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
                VStack(spacing: 0) {
                    controls
                    if !compact { columnHeader }
                    Divider()
                    if visibleTunnels.isEmpty {
                        VStack(spacing: 10) {
                            Text("No tunnel matches").font(.headline)
                            Text("Search: \(search.isEmpty ? "none" : "“\(search)”") · State: \(stateFilter.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Clear filters") { search = ""; stateFilter = .all }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(visibleTunnels, selection: $selectedTunnel) { tunnel in
                            TunnelRowView(tunnel: tunnel, filter: filter,
                                          signedInCount: filter == .shared || tunnel.scope == .managed ? signedInCount : nil)
                                .environmentObject(tunnelManager)
                                .tag(tunnel)
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
        }
        .task(id: filter) {
            guard filter == .shared else { return }
            let accounts = await Task.detached { MacAccountsService.load() }.value
            signedInCount = accounts.filter { $0.state.isSignedIn }.count
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
        case .multiHop, .profiles, .doctor, .mesh, .devTools, .settings, .log:
            return ""
        }
    }
}
