import SwiftUI
import Combine

struct MainDashboardView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var dashboardNavigation: DashboardNavigation
    @EnvironmentObject var updaterService: UpdaterService
    @State private var selection: SidebarItem = .all
    @State private var tunnelFilter: SidebarItem = .all
    @State private var selectedTunnel: Tunnel? = nil
    @State private var showingImport = false
    @State private var showingNewTunnel = false
    /// A config handed from Import Config to the Advanced Editor so its errors can be fixed there.
    @State private var newTunnelDraft: (config: String, name: String)?
    /// The tunnel shown as a full-width page, and the tab to open when going back to the detail pane.
    @State private var fullDetailsTunnel: Tunnel? = nil
    @State private var detailTab: TunnelDetailTab = .overview

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
        .environmentObject(tunnelManager.monitor)
        .onReceive(dashboardNavigation.$requestedSidebar.compactMap { $0 }) { item in
            selection = item
            dashboardNavigation.consumeSidebarRequest()
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
            fullDetailsTunnel = nil
        }
        .onChange(of: selectedTunnel?.id) { _, _ in
            detailTab = .overview
            fullDetailsTunnel = nil
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
            ImportConfigView(onFixInEditor: { config, name in
                newTunnelDraft = (config, name)
                showingImport = false
                // The editor opens once the import sheet has finished closing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingNewTunnel = true }
            })
            .environmentObject(tunnelManager)
        }
        .sheet(isPresented: $showingNewTunnel, onDismiss: { newTunnelDraft = nil }) {
            NewTunnelView(initialConfig: newTunnelDraft?.config, initialName: newTunnelDraft?.name ?? "")
                .environmentObject(tunnelManager)
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            FeedbackBanner()
            workspaceContent
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
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
        VStack(spacing: 0) {
            if let tunnel = fullDetailsTunnel {
                TunnelFullDetailsView(
                    tunnel: tunnel,
                    onClose: { fullDetailsTunnel = nil },
                    onOpenTab: { tab in
                        detailTab = tab
                        fullDetailsTunnel = nil
                    }
                )
                .environmentObject(tunnelManager)
            } else {
                TunnelSummaryBanner(filter: tunnelFilter)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                // Active lists session columns, so its list gets more of the width.
                MasterDetail(masterFraction: tunnelFilter == .active ? 0.66 : 0.46,
                             masterMax: tunnelFilter == .active ? 720 : 600) {
                    TunnelListView(filter: tunnelFilter, selectedTunnel: $selectedTunnel)
                        .environmentObject(tunnelManager)
                } detail: {
                    detailView
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
        case .multiHop:
            HopChainView()
                .environmentObject(tunnelManager)
        case .profiles:
            NetworkProfilesView(manager: tunnelManager.networkProfiles, tunnels: tunnelManager.tunnels)
        case .doctor:
            NetworkDoctorView(doctor: tunnelManager.networkDoctor)
                .environmentObject(tunnelManager)
        case .mesh:
            MeshVPNView(manager: tunnelManager.meshVPNs)
                .environmentObject(tunnelManager)
        case .devTools:
            DevToolsView(manager: tunnelManager.devTools)
        case .warnings:
            WarningsView()
                .environmentObject(tunnelManager)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let tunnel = selectedTunnel {
            TunnelDetailView(tunnel: tunnel, initialTab: detailTab, onFullDetails: { fullDetailsTunnel = tunnel })
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
        case .multiHop:  return .indigo
        case .profiles:  return .teal
        case .doctor:    return .mint
        case .mesh:      return .cyan
        case .devTools:  return .brown
        case .warnings:  return .orange
        case .settings:  return .gray
        case .log:       return .blue
        case .all:       return .accentColor
        }
    }
}

