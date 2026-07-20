import SwiftUI
import Charts
import UniformTypeIdentifiers

// MARK: - Helpers

func formatBytes(_ bytes: Int64) -> String {
    let absBytes = abs(bytes)
    switch absBytes {
    case 0 ..< 1_024:
        return "\(bytes) B"
    case 1_024 ..< 1_048_576:
        let kb = Double(bytes) / 1_024
        return String(format: "%.1f KB", kb)
    case 1_048_576 ..< 1_073_741_824:
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.2f MB", mb)
    default:
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.2f GB", gb)
    }
}

func formatDuration(since start: Date) -> String {
    let s = Int(Date.now.timeIntervalSince(start))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    let h = s / 3600; let m = (s % 3600) / 60
    return "\(h)h \(m)m"
}

func formatHandshake(_ date: Date?) -> String {
    guard let date else { return "Never" }
    let elapsed = Date.now.timeIntervalSince(date)
    switch elapsed {
    case 0 ..< 60:
        let secs = Int(elapsed)
        return "\(secs) second\(secs == 1 ? "" : "s") ago"
    case 60 ..< 3_600:
        let mins = Int(elapsed / 60)
        return "\(mins) minute\(mins == 1 ? "" : "s") ago"
    case 3_600 ..< 86_400:
        let hrs = Int(elapsed / 3_600)
        return "\(hrs) hour\(hrs == 1 ? "" : "s") ago"
    default:
        return tunnelRelativeDateFormatter.localizedString(for: date, relativeTo: .now)
    }
}

private let tunnelRelativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
}()

// MARK: - Detail View

struct TunnelDetailView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    let tunnel: Tunnel
    @State private var showingEditor = false
    @State private var showingDeleteConfirm = false
    @State private var showingManagedReplacement = false
    @State private var showingQRCode = false
    @State private var isTestingConnection = false
    @State private var connectionTestResult: String? = nil
    @State private var isSharingTunnel = false
    @State private var isProcessing = false
    @State private var isLoadingConnectedUsers = false
    @State private var connectedUsers: [ManagedTunnelUserSession] = []
    @State private var errorMessage: String? = nil

    // On-Demand state — mirrors live.autoConnectRule, saved immediately on change.
    // Connect and disconnect are independent halves so a tunnel can e.g. connect
    // on the office Wi-Fi and disconnect on a public hotspot at the same time.
    @State private var connectEnabled: Bool                   = false
    @State private var connectInterface: AutoConnectInterface = .wifi
    @State private var connectAnyWiFi: Bool                   = true
    @State private var connectSSIDs: [String]                 = []
    @State private var connectNewSSID: String                 = ""

    @State private var disconnectEnabled: Bool                   = false
    @State private var disconnectInterface: AutoConnectInterface = .wifi
    @State private var disconnectAnyWiFi: Bool                   = true
    @State private var disconnectSSIDs: [String]                 = []
    @State private var disconnectNewSSID: String                 = ""

    @State private var knownNetworks: [String] = []

    // Kill switch — mirrors live.isKillSwitchEnabled, saved immediately on change.
    @State private var killSwitchEnabled: Bool = false

    // Always read live data from TunnelManager so stats update in real-time
    private var live: Tunnel {
        tunnelManager.tunnels.first(where: { $0.id == tunnel.id }) ?? tunnel
    }

    private var isManaged: Bool {
        live.scope == .managed
    }

    /// Shared tunnels' on-demand rule is set once by an administrator and applies to everyone;
    /// only the administrator may change it, and personal tunnels are always editable.
    private var canEditOnDemand: Bool {
        !isManaged || tunnelManager.currentUserIsAdministrator
    }

    private var connectionDisabled: Bool {
        isProcessing
            || (isManaged && live.isActive && live.managedPolicy?.usersCanDisconnect == false)
            || (isManaged && !live.isActive && live.managedPolicy?.usersCanConnect == false)
    }

    private var confType: UTType {
        UTType(filenameExtension: "conf") ?? .plainText
    }

    private var connectionBinding: Binding<Bool> {
        Binding(
            get: { live.isActive },
            set: { shouldConnect in
                guard shouldConnect != live.isActive, !isProcessing else { return }
                isProcessing = true
                Task {
                    if shouldConnect {
                        await tunnelManager.connectTunnel(live)
                    } else {
                        await tunnelManager.disconnectTunnel(live)
                    }
                    isProcessing = false
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                Divider()

                // Interface details
                DetailSection(title: "Interface") {
                    if let iface = live.interfaceName {
                        DetailRow(label: "Interface", value: iface)
                    }
                    if let addrs = live.address, !addrs.isEmpty {
                        DetailRow(label: "Address", value: addrs.joined(separator: ", "), monospace: true)
                    }
                    if let endpoint = live.endpoint {
                        DetailRow(label: "Endpoint", value: endpoint)
                    }
                    if !live.allowedIPs.isEmpty {
                        DetailRow(label: "Allowed IPs", value: live.allowedIPs.joined(separator: "\n"))
                    }
                    if !live.dns.isEmpty {
                        DetailRow(label: "DNS", value: live.dns.joined(separator: ", "))
                    }
                    if let pubKey = live.publicKey, !pubKey.isEmpty {
                        DetailRow(label: "Public Key", value: pubKey, monospace: true)
                    }
                }

                Divider()

                // Runtime stats
                DetailSection(title: "Status") {
                    if let connectedAt = live.connectedAt {
                        DetailRow(label: "Connected for", value: formatDuration(since: connectedAt))
                    }
                    DetailRow(label: "Last Handshake", value: formatHandshake(live.lastHandshake))
                    DetailRow(label: "Received", value: formatBytes(live.rxBytes))
                    DetailRow(label: "Sent", value: formatBytes(live.txBytes))

                    HStack(spacing: 10) {
                        Button {
                            testConnection()
                        } label: {
                            if isTestingConnection {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Test Connection", systemImage: "waveform.path.ecg")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!live.isActive || isTestingConnection)
                        .help("Pings this tunnel's own VPN server to check latency.")

                        if let connectionTestResult {
                            Text(connectionTestResult)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if isManaged && tunnelManager.currentUserIsAdministrator {
                    Divider()
                    connectedUsersSection
                }

                // Traffic charts — only when active and samples exist
                let samples = tunnelManager.trafficHistory[live.id] ?? []
                if live.isActive && !samples.isEmpty {
                    Divider()
                    TrafficChartsView(tunnel: live, samples: samples)
                }

                Divider()

                // On-Demand (Auto-Connect)
                onDemandSection

                Divider()

                // Kill Switch
                killSwitchSection

                Divider()

                // Config path
                DetailSection(title: "Configuration") {
                    if isManaged {
                        DetailRow(label: "Scope", value: "Visible to all users")
                        DetailRow(label: "Editing", value: "Administrator only")
                    } else {
                        DetailRow(label: "Config Path", value: live.configPath, monospace: true)
                    }
                    if let rtPath = live.runtimeConfigPath, !isManaged {
                        DetailRow(label: "Runtime Path", value: rtPath, monospace: true)
                    }
                    DetailRow(label: "Autostart", value: live.autostart ? "Enabled" : "Disabled")
                    DetailRow(label: "Created", value: live.createdAt.formatted(date: .abbreviated, time: .shortened))
                    DetailRow(label: "Updated", value: live.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                Divider()

                // Actions
                actionsSection
            }
            .padding(20)
        }
        .navigationTitle(live.name)
        .onAppear {
            loadRule()
            killSwitchEnabled = live.isKillSwitchEnabled
        }
        .onChange(of: live.autoConnectRule) { _, _ in loadRule() }
        .onChange(of: live.isKillSwitchEnabled) { _, newValue in killSwitchEnabled = newValue }
        .task {
            knownNetworks = await Task.detached { NetworkMonitorService.knownWiFiNetworkNames() }.value
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete \"\(live.name)\"?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if isManaged {
                    Task { await tunnelManager.deleteManagedTunnel(live) }
                } else {
                    tunnelManager.deleteTunnel(live)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isManaged
                 ? "This action requires administrator approval."
                 : "This action cannot be undone. The tunnel configuration file will be removed.")
        }
        .sheet(isPresented: $showingEditor) {
            ConfigEditorSheetView(tunnel: live)
                .environmentObject(tunnelManager)
        }
        .sheet(isPresented: $showingQRCode) {
            QRCodeSheetView(tunnel: live)
                .environmentObject(tunnelManager)
        }
        .fileImporter(
            isPresented: $showingManagedReplacement,
            allowedContentTypes: [confType, .plainText]
        ) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        try await tunnelManager.replaceManagedConfig(live, with: url)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Sections

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 14) {
            // Status badge
            ZStack {
                Circle()
                    .fill(live.isActive ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 52, height: 52)

                Image(systemName: live.isActive ? "network" : "network.slash")
                    .font(.title2)
                    .foregroundStyle(live.isActive ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(live.name)
                    .font(.title2.bold())

                HStack(spacing: 6) {
                    Circle()
                        .fill(live.isActive ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(live.isActive ? "Connected" : "Disconnected")
                        .font(.subheadline)
                        .foregroundStyle(live.isActive ? .green : .secondary)

                    if live.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }

                    if isManaged {
                        Label("Shared for All Users", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }

                Toggle(isOn: connectionBinding) {
                    Text("Connection")
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(connectionDisabled)
                .accessibilityLabel("Connection for \(live.name)")
            }
        }
    }

    // MARK: On-Demand Section

    private var connectedUsersSection: some View {
        DetailSection(title: "Connected Users") {
            if isLoadingConnectedUsers {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if connectedUsers.isEmpty {
                Text("Visible to administrators.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(connectedUsers) { session in
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundStyle(.secondary)
                            Text(session.username)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(session.connectedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Button {
                loadConnectedUsers()
            } label: {
                Label("Show Connected Users", systemImage: "person.2")
            }
            .buttonStyle(.bordered)
            .disabled(isLoadingConnectedUsers)
        }
    }

    private var onDemandSection: some View {
        DetailSection(title: "On-Demand") {
            if isManaged {
                Text(tunnelManager.currentUserIsAdministrator
                     ? "As administrator, changes here apply to all users of this shared tunnel."
                     : "Set by your administrator and applied to all users. You can't change it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Connect and disconnect rules are independent — a tunnel can connect on one network and disconnect on another.")
                .font(.caption)
                .foregroundStyle(.secondary)

            OnDemandMatchSection(
                title: "Connect",
                systemImage: "bolt.fill",
                enabled: $connectEnabled,
                interface: $connectInterface,
                anyWiFi: $connectAnyWiFi,
                ssids: $connectSSIDs,
                newSSID: $connectNewSSID,
                knownNetworks: knownNetworks,
                currentSSID: tunnelManager.networkMonitor.currentSSID,
                canEdit: canEditOnDemand,
                hasWiFiNamePermission: tunnelManager.networkMonitor.hasWiFiNamePermission,
                onRequestWiFiPermission: { tunnelManager.networkMonitor.requestWiFiNamePermissionIfNeeded() },
                onOpenLocationSettings: { tunnelManager.networkMonitor.openLocationSettings() },
                onSave: saveRule
            )

            Divider()

            OnDemandMatchSection(
                title: "Disconnect",
                systemImage: "bolt.slash.fill",
                enabled: $disconnectEnabled,
                interface: $disconnectInterface,
                anyWiFi: $disconnectAnyWiFi,
                ssids: $disconnectSSIDs,
                newSSID: $disconnectNewSSID,
                knownNetworks: knownNetworks,
                currentSSID: tunnelManager.networkMonitor.currentSSID,
                canEdit: canEditOnDemand,
                hasWiFiNamePermission: tunnelManager.networkMonitor.hasWiFiNamePermission,
                onRequestWiFiPermission: { tunnelManager.networkMonitor.requestWiFiNamePermissionIfNeeded() },
                onOpenLocationSettings: { tunnelManager.networkMonitor.openLocationSettings() },
                onSave: saveRule
            )

            if connectEnabled || disconnectEnabled {
                Divider()
                HStack(spacing: 16) {
                    onDemandStatusIndicator(
                        label: "Connect",
                        matches: connectEnabled && tunnelManager.networkMonitor.matchesConnect(live)
                    )
                    onDemandStatusIndicator(
                        label: "Disconnect",
                        matches: disconnectEnabled && tunnelManager.networkMonitor.matchesDisconnect(live)
                    )
                }
            }
        }
    }

    private func onDemandStatusIndicator(label: String, matches: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(matches ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text("\(label) rule \(matches ? "matches" : "doesn't match") current network")
                .font(.caption)
                .foregroundStyle(matches ? .green : .secondary)
        }
    }

    // MARK: On-Demand Helpers

    private func loadRule() {
        let rule = live.autoConnectRule

        connectEnabled   = rule.connect.enabled
        connectInterface = rule.connect.interface
        connectAnyWiFi   = rule.connect.matchesAnyWiFi
        connectSSIDs     = rule.connect.wifiSSIDs
        connectNewSSID   = ""

        disconnectEnabled   = rule.disconnect.enabled
        disconnectInterface = rule.disconnect.interface
        disconnectAnyWiFi   = rule.disconnect.matchesAnyWiFi
        disconnectSSIDs     = rule.disconnect.wifiSSIDs
        disconnectNewSSID   = ""
    }

    private func saveRule() {
        guard canEditOnDemand else { return }
        let rule = AutoConnectRule(
            connect: AutoConnectNetworkMatch(
                enabled: connectEnabled,
                interface: connectInterface,
                wifiSSIDs: connectAnyWiFi ? [] : connectSSIDs
            ),
            disconnect: AutoConnectNetworkMatch(
                enabled: disconnectEnabled,
                interface: disconnectInterface,
                wifiSSIDs: disconnectAnyWiFi ? [] : disconnectSSIDs
            )
        )
        if isManaged {
            Task {
                do {
                    try await tunnelManager.updateManagedAutoConnectRule(for: live, rule: rule)
                } catch {
                    errorMessage = error.localizedDescription
                    loadRule() // revert the UI to the last confirmed shared state
                }
            }
        } else {
            tunnelManager.updateAutoConnectRule(for: live, rule: rule)
        }
    }

    // MARK: Kill Switch

    private var killSwitchSection: some View {
        DetailSection(title: "Kill Switch") {
            if isManaged {
                Text(tunnelManager.currentUserIsAdministrator
                     ? "As administrator, changes here apply to all users of this shared tunnel."
                     : "Set by your administrator and applied to all users. You can't change it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $killSwitchEnabled) {
                Label("Block traffic if this tunnel drops", systemImage: "shield.lefthalf.filled")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.switch)
            .disabled(!canEditOnDemand)
            .onChange(of: killSwitchEnabled) { _, _ in saveKillSwitch() }

            Text("Blocks all other network traffic until this tunnel reconnects. Disconnecting it yourself does not trigger a block.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveKillSwitch() {
        guard canEditOnDemand else { return }
        if isManaged {
            Task {
                do {
                    try await tunnelManager.updateManagedKillSwitch(for: live, enabled: killSwitchEnabled)
                } catch {
                    errorMessage = error.localizedDescription
                    killSwitchEnabled = live.isKillSwitchEnabled // revert the UI to the last confirmed shared state
                }
            }
        } else {
            tunnelManager.updateKillSwitch(for: live, enabled: killSwitchEnabled)
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 12) {
            if !isManaged {
                Button {
                    tunnelManager.toggleFavorite(live)
                } label: {
                    Label(
                        live.isFavorite ? "Remove Favorite" : "Add Favorite",
                        systemImage: live.isFavorite ? "star.slash" : "star"
                    )
                }
                .buttonStyle(.bordered)

                Button {
                    showingEditor = true
                } label: {
                    Label("Edit Config", systemImage: "pencil")
                }
                .buttonStyle(.bordered)

                Button {
                    makeShared()
                } label: {
                    Label("Make Shared", systemImage: "person.2.fill")
                }
                .buttonStyle(.bordered)
                .disabled(live.isActive || isSharingTunnel)
                .help(live.isActive
                      ? "Disconnect the tunnel before making it visible to all users."
                      : "Make this tunnel visible to all users. Administrator approval is required.")

                Button {
                    showingQRCode = true
                } label: {
                    Label("Show QR Code", systemImage: "qrcode")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    showingManagedReplacement = true
                } label: {
                    Label("Replace Managed Config", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(live.isActive)
            }

            Spacer()

            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label(isManaged ? "Delete Managed Tunnel" : "Delete Tunnel", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(live.isActive)
            .help(live.isActive ? "Disconnect the tunnel before deleting." : "Delete this tunnel permanently.")
        }
    }

    private func testConnection() {
        isTestingConnection = true
        connectionTestResult = nil
        Task {
            switch await tunnelManager.testConnection(for: live) {
            case .success(let averageMs):
                connectionTestResult = String(format: "%.0f ms avg", averageMs)
            case .unreachable:
                connectionTestResult = "Unreachable"
            case .unknownEndpoint:
                connectionTestResult = "Endpoint unknown"
            }
            isTestingConnection = false
        }
    }

    private func makeShared() {
        isSharingTunnel = true
        Task {
            do {
                try await tunnelManager.makeTunnelShared(live)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSharingTunnel = false
        }
    }

    private func loadConnectedUsers() {
        isLoadingConnectedUsers = true
        Task {
            do {
                connectedUsers = try await tunnelManager.connectedUsers(for: live)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoadingConnectedUsers = false
        }
    }
}

// MARK: - On-Demand Match Section

/// Editor for one half (connect or disconnect) of an on-demand rule. Two of these
/// are shown side by side in TunnelDetailView so the connect and disconnect
/// network lists can be configured independently.
private struct OnDemandMatchSection: View {
    let title: String
    let systemImage: String
    @Binding var enabled: Bool
    @Binding var interface: AutoConnectInterface
    @Binding var anyWiFi: Bool
    @Binding var ssids: [String]
    @Binding var newSSID: String
    let knownNetworks: [String]
    let currentSSID: String?
    let canEdit: Bool
    let hasWiFiNamePermission: Bool
    let onRequestWiFiPermission: () -> Void
    let onOpenLocationSettings: () -> Void
    let onSave: () -> Void

    private var showWiFiOptions: Bool {
        enabled && (interface == .wifi || interface == .both)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.switch)
            .disabled(!canEdit)
            .onChange(of: enabled) { _, _ in onSave() }

            if enabled {
                HStack {
                    Text("\(title) on")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)

                    Picker("", selection: $interface) {
                        ForEach(AutoConnectInterface.allCases, id: \.self) { iface in
                            Text(iface.displayName).tag(iface)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(!canEdit)
                    .onChange(of: interface) { _, _ in onSave() }
                }

                if showWiFiOptions {
                    Toggle("Any Wi-Fi Network", isOn: $anyWiFi)
                        .toggleStyle(.checkbox)
                        .disabled(!canEdit)
                        .onChange(of: anyWiFi) { _, isAny in
                            // Only save when switching TO "any network" (clearing the list).
                            // Switching away with a still-empty list must not save yet —
                            // an empty list round-trips as matchesAnyWiFi == true and would
                            // immediately flip this toggle back on via the parent's reload,
                            // wiping out whatever the user is about to type into the SSID field.
                            guard isAny else {
                                onRequestWiFiPermission()
                                return
                            }
                            ssids = []
                            onSave()
                        }

                    if !anyWiFi {
                        if !hasWiFiNamePermission {
                            wifiPermissionWarning
                        }

                        // SSID list
                        if !ssids.isEmpty {
                            VStack(spacing: 4) {
                                ForEach(ssids, id: \.self) { ssid in
                                    HStack {
                                        Image(systemName: "wifi")
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                        Text(ssid)
                                            .font(.system(.subheadline, design: .monospaced))
                                        Spacer()
                                        Button {
                                            ssids.removeAll { $0 == ssid }
                                            onSave()
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(!canEdit)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }

                        // Known networks (from System Settings > Wi-Fi)
                        let selectableKnownNetworks = knownNetworks.filter { !ssids.contains($0) }
                        if !selectableKnownNetworks.isEmpty {
                            Menu {
                                ForEach(selectableKnownNetworks, id: \.self) { network in
                                    Button(network) {
                                        ssids.append(network)
                                        onSave()
                                    }
                                }
                            } label: {
                                Label("Add Known Network…", systemImage: "wifi")
                            }
                            .disabled(!canEdit)
                        }

                        // Manual entry — fallback for networks not in the known list above
                        HStack {
                            TextField("Or type SSID manually", text: $newSSID)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit { addSSID() }
                            Button("Add") { addSSID() }
                                .buttonStyle(.bordered)
                                .disabled(!canEdit ||
                                          newSSID.trimmingCharacters(in: .whitespaces).isEmpty ||
                                          ssids.contains(newSSID.trimmingCharacters(in: .whitespaces)))
                        }

                        // Add current network shortcut
                        if let currentSSID, !ssids.contains(currentSSID) {
                            Button {
                                ssids.append(currentSSID)
                                onSave()
                            } label: {
                                Label("Add Current: \"\(currentSSID)\"", systemImage: "wifi.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!canEdit)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var wifiPermissionWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "WireTunnels needs Location access to read the Wi-Fi network name. Without it, rules for specific networks won't trigger — enable it in System Settings > Privacy & Security > Location Services.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)

            Button("Open Location Settings") {
                onOpenLocationSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func addSSID() {
        let s = newSSID.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !ssids.contains(s) else { return }
        ssids.append(s)
        newSSID = ""
        onSave()
    }
}

// MARK: - Supporting Views

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var monospace: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)

            Text(value)
                .font(monospace ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Traffic Charts

private struct TrafficChartsView: View {
    let tunnel: Tunnel
    let samples: [TrafficSample]

    private var lastRxRate: Double { samples.last?.rxRate ?? 0 }
    private var lastTxRate: Double { samples.last?.txRate ?? 0 }

    var body: some View {
        DetailSection(title: "Traffic (last 60s)") {
            // RX
            HStack {
                Label(formatBytes(Int64(lastRxRate)) + "/s", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.monospacedDigit())
                Spacer()
                Text("Total received: \(formatBytes(tunnel.rxBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart(samples) { s in
                AreaMark(x: .value("Time", s.timestamp), y: .value("RX", s.rxRate))
                    .foregroundStyle(.green.opacity(0.15))
                LineMark(x: .value("Time", s.timestamp), y: .value("RX", s.rxRate))
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatBytes(Int64(v)) + "/s")
                                .font(.system(.caption2, design: .monospaced))
                        }
                    }
                }
            }
            .frame(height: 64)

            // TX
            HStack {
                Label(formatBytes(Int64(lastTxRate)) + "/s", systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.subheadline.monospacedDigit())
                Spacer()
                Text("Total sent: \(formatBytes(tunnel.txBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart(samples) { s in
                AreaMark(x: .value("Time", s.timestamp), y: .value("TX", s.txRate))
                    .foregroundStyle(.blue.opacity(0.15))
                LineMark(x: .value("Time", s.timestamp), y: .value("TX", s.txRate))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatBytes(Int64(v)) + "/s")
                                .font(.system(.caption2, design: .monospaced))
                        }
                    }
                }
            }
            .frame(height: 64)
        }
    }
}

// MARK: - Config Editor Sheet Wrapper

private struct ConfigEditorSheetView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @Environment(\.dismiss) var dismiss
    let tunnel: Tunnel

    @State private var selectedTab = 1  // default: Advanced Editor
    @State private var tunnelName: String = ""
    // Basic form fields
    @State private var privateKey: String = ""
    @State private var address: String = ""
    @State private var dns: String = ""
    @State private var peerPublicKey: String = ""
    @State private var presharedKey: String = ""
    @State private var endpoint: String = ""
    @State private var allowedIPs: String = ""
    @State private var persistentKeepalive: String = ""
    // Advanced editor
    @State private var advancedContent: String = ""

    @State private var isSaving = false
    @State private var error: String? = nil

    private var generatedConfig: String {
        """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(address)
        \(dns.isEmpty ? "" : "DNS = \(dns)\n")
        [Peer]
        PublicKey = \(peerPublicKey)
        \(presharedKey.isEmpty ? "" : "PresharedKey = \(presharedKey)\n")Endpoint = \(endpoint)
        AllowedIPs = \(allowedIPs)
        \(persistentKeepalive.isEmpty ? "" : "PersistentKeepalive = \(persistentKeepalive)\n")
        """
    }

    private var effectiveConfig: String {
        selectedTab == 0 ? generatedConfig : advancedContent
    }

    private var canSave: Bool {
        let name = tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedTab == 0 {
            return !name.isEmpty && !privateKey.isEmpty && !address.isEmpty
        } else {
            return !name.isEmpty && !advancedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Config — \(tunnel.name)")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Picker("", selection: $selectedTab) {
                Text("Basic Form").tag(0)
                Text("Advanced Editor").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if selectedTab == 0 {
                basicFormView
            } else {
                advancedEditorView
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || isSaving)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 600)
        .onAppear { loadFields() }
        .alert("Save Error", isPresented: .init(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var basicFormView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FormSection(title: "General") {
                    FormRow(label: "Tunnel Name") {
                        TextField("my_vpn", text: $tunnelName)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                FormSection(title: "Interface") {
                    FormRow(label: "Private Key") {
                        SecureField("Base64 encoded key", text: $privateKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    FormRow(label: "Address") {
                        TextField("10.0.0.2/24", text: $address)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    FormRow(label: "DNS") {
                        TextField("1.1.1.1", text: $dns)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                FormSection(title: "Peer") {
                    FormRow(label: "Public Key") {
                        TextField("Server public key", text: $peerPublicKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    FormRow(label: "Preshared Key") {
                        TextField("Optional", text: $presharedKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    FormRow(label: "Endpoint") {
                        TextField("vpn.example.com:51820", text: $endpoint)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    FormRow(label: "Allowed IPs") {
                        TextField("0.0.0.0/0", text: $allowedIPs)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    FormRow(label: "Keepalive") {
                        TextField("25", text: $persistentKeepalive)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                    }
                }
            }
            .padding()
        }
    }

    private var advancedEditorView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text("Tunnel Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
                TextField("my_vpn", text: $tunnelName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ConfigEditorView(content: $advancedContent)
                .padding(8)
        }
    }

    private func loadFields() {
        tunnelName = tunnel.name
        advancedContent = (try? String(contentsOfFile: tunnel.configPath, encoding: .utf8)) ?? ""
        let parsed = WireGuardConfigParser().parse(string: advancedContent)
        privateKey = parsed.privateKey ?? ""
        address = parsed.address.joined(separator: ", ")
        dns = parsed.dns.joined(separator: ", ")
        peerPublicKey = parsed.peerPublicKey ?? ""
        presharedKey = parsed.presharedKey ?? ""
        endpoint = parsed.endpoint ?? ""
        allowedIPs = parsed.allowedIPs.joined(separator: ", ")
        persistentKeepalive = parsed.persistentKeepalive.map { String($0) } ?? ""
    }

    private func save() {
        let sanitizedName = ConfigStorageService.sanitize(name: tunnelName)
        isSaving = true
        Task {
            do {
                try await tunnelManager.updateTunnel(tunnel, name: sanitizedName, configContent: effectiveConfig)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
}

// MARK: - QR Code Sheet

private struct QRCodeSheetView: View {
    @Environment(\.dismiss) var dismiss
    let tunnel: Tunnel

    @State private var qrImage: NSImage? = nil
    @State private var loadError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("QR Code — \(tunnel.name)")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            VStack(spacing: 16) {
                Label("Contains this tunnel's private key — only share it with a device you trust.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 260, height: 260)
                } else {
                    Text(loadError ?? "Unable to generate QR code for this tunnel.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 260, height: 260)
                }

                Text("Scan with the WireGuard app on another device to import this tunnel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 380, height: 460)
        .onAppear { loadQRCode() }
    }

    private func loadQRCode() {
        guard let contents = try? String(contentsOfFile: tunnel.configPath, encoding: .utf8) else {
            loadError = "Unable to read this tunnel's configuration."
            return
        }
        guard let image = QRCodeService.generate(from: contents) else {
            loadError = "This configuration is too large to encode as a QR code."
            return
        }
        qrImage = image
    }
}
