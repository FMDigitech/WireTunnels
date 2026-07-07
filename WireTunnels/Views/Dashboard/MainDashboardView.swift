import SwiftUI
import Combine

enum SidebarItem: String, CaseIterable, Hashable {
    case all = "All Tunnels"
    case active = "Active"
    case shared = "Shared"
    case favorites = "Favorites"
    case warnings = "Warnings"
    case settings = "Settings"
    case log = "Log"

    var systemImage: String {
        switch self {
        case .all:       return "list.bullet"
        case .active:    return "bolt.fill"
        case .shared:    return "person.2.fill"
        case .favorites: return "star.fill"
        case .warnings:  return "exclamationmark.triangle.fill"
        case .settings:  return "gear"
        case .log:       return "doc.text"
        }
    }

    var usesTunnelDetail: Bool {
        switch self {
        case .all, .active, .shared, .favorites:
            return true
        case .warnings, .settings, .log:
            return false
        }
    }
}

struct MainDashboardView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var dashboardNavigation: DashboardNavigation
    @EnvironmentObject var updaterService: UpdaterService
    @State private var selection: SidebarItem = .all
    @State private var tunnelFilter: SidebarItem = .all
    @State private var selectedTunnel: Tunnel? = nil
    @State private var showingImport = false
    @State private var showingNewTunnel = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            workspace
        }
        .overlay {
            if !tunnelManager.isInitialized || tunnelManager.needsSetup {
                SetupWizardView()
                    .environmentObject(tunnelManager)
            }
        }
        .onAppear {
            tunnelManager.startPolling(interval: 2.0)
        }
        .onDisappear {
            tunnelManager.startPolling(interval: 10.0)
        }
        .onChange(of: selection) { _, newSelection in
            if newSelection.usesTunnelDetail {
                tunnelFilter = newSelection
            }
        }
        .onReceive(dashboardNavigation.$requestedTunnelID.compactMap { $0 }) { tunnelID in
            selection = .all
            tunnelFilter = .all
            dashboardNavigation.consumeRequest(tunnelID)
            selectedTunnel = tunnelManager.tunnels.first { $0.id == tunnelID }
        }
        .onChange(of: tunnelManager.tunnels) { _, tunnels in
            guard let selected = selectedTunnel else { return }
            if let current = tunnels.first(where: { $0.id == selected.id }) {
                if current != selected {
                    selectedTunnel = current
                }
            } else {
                selectedTunnel = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDataDidReset)) { _ in
            selectedTunnel = nil
            selection = .all
            tunnelFilter = .all
        }
        .alert("WireTunnels Error", isPresented: managerErrorBinding) {
            Button("OK") {
                tunnelManager.errorMessage = nil
            }
        } message: {
            Text(tunnelManager.errorMessage ?? "")
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingImport = true
                } label: {
                    Label("Import Config", systemImage: "square.and.arrow.down")
                }
                .help("Import a .conf file")

                Button {
                    showingNewTunnel = true
                } label: {
                    Label("New Tunnel", systemImage: "plus")
                }
                .help("Create a new tunnel")
            }
        }
        .sheet(isPresented: $showingImport) {
            ImportConfigView()
                .environmentObject(tunnelManager)
        }
        .sheet(isPresented: $showingNewTunnel) {
            NewTunnelView()
                .environmentObject(tunnelManager)
        }
    }

    @ViewBuilder
    private var workspace: some View {
        ZStack {
            tunnelWorkspace
                .opacity(selection.usesTunnelDetail ? 1 : 0)
                .allowsHitTesting(selection.usesTunnelDetail)
                .accessibilityHidden(!selection.usesTunnelDetail)

            if !selection.usesTunnelDetail {
                globalContentView
            }
        }
    }

    private var sidebar: some View {
        SidebarView(selection: $selection, selectedTunnel: $selectedTunnel)
    }

    private var managerErrorBinding: Binding<Bool> {
        Binding(
            get: {
                // Suppress alert while wizard is handling setup errors
                tunnelManager.errorMessage != nil
                    && tunnelManager.isInitialized
                    && !tunnelManager.needsSetup
            },
            set: { isPresented in
                guard !isPresented else { return }
                tunnelManager.errorMessage = nil
            }
        )
    }

    private var tunnelWorkspace: some View {
        HSplitView {
            TunnelListView(filter: tunnelFilter, selectedTunnel: $selectedTunnel)
                .environmentObject(tunnelManager)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

            detailView
                .frame(minWidth: 320)
        }
    }

    @ViewBuilder
    private var globalContentView: some View {
        switch selection {
        case .settings:
            SettingsView()
                .environmentObject(tunnelManager)
                .environmentObject(updaterService)
        case .log:
            LogView()
        case .warnings:
            WarningsListView()
                .environmentObject(tunnelManager)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let tunnel = selectedTunnel {
            TunnelDetailView(tunnel: tunnel)
                .environmentObject(tunnelManager)
                .id(tunnel.id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Select a tunnel")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Choose a tunnel from the list to view its details.")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @Binding var selection: SidebarItem
    @Binding var selectedTunnel: Tunnel?

    var body: some View {
        List(SidebarItem.allCases, id: \.self, selection: $selection) { item in
            Label {
                HStack {
                    Text(item.rawValue)
                    Spacer()
                    badgeView(for: item)
                }
            } icon: {
                Image(systemName: item.systemImage)
                    .foregroundStyle(iconColor(for: item))
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("WireTunnels")
        .onChange(of: selection) { _, _ in
            selectedTunnel = nil
        }
    }

    @ViewBuilder
    private func badgeView(for item: SidebarItem) -> some View {
        switch item {
        case .active:
            let count = tunnelManager.activeTunnelCount
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green, in: Capsule())
            }
        case .warnings:
            let count = tunnelManager.activeWarnings.count
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.yellow, in: Capsule())
            }
        case .favorites:
            let count = tunnelManager.favoriteTunnels.count
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
            }
        case .shared:
            let count = tunnelManager.sharedTunnels.count
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
            }
        default:
            EmptyView()
        }
    }

    private func iconColor(for item: SidebarItem) -> Color {
        switch item {
        case .active:    return .green
        case .shared:    return .purple
        case .favorites: return .yellow
        case .warnings:  return .orange
        case .settings:  return .gray
        case .log:       return .blue
        case .all:       return .accentColor
        }
    }
}

// MARK: - Warnings List

private struct WarningsListView: View {
    @EnvironmentObject var tunnelManager: TunnelManager

    var body: some View {
        if tunnelManager.activeWarnings.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                Text("No Warnings")
                    .font(.headline)
                Text("Your tunnel configuration looks good.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(tunnelManager.activeWarnings) { warning in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(warning.title)
                            .font(.headline)
                    }
                    Text(warning.message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Warnings")
        }
    }
}
