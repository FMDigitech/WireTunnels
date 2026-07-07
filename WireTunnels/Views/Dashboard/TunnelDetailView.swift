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
    @State private var isSharingTunnel = false
    @State private var isProcessing = false
    @State private var isLoadingConnectedUsers = false
    @State private var connectedUsers: [ManagedTunnelUserSession] = []
    @State private var errorMessage: String? = nil

    // On-Demand state — mirrors live.autoConnectRule, saved immediately on change
    @State private var ruleEnabled: Bool                   = false
    @State private var ruleInterface: AutoConnectInterface = .wifi
    @State private var ruleAction: AutoConnectAction       = .connect
    @State private var ruleAnyWiFi: Bool                   = true
    @State private var ruleSSIDs: [String]                 = []
    @State private var newSSID: String                     = ""

    // Always read live data from TunnelManager so stats update in real-time
    private var live: Tunnel {
        tunnelManager.tunnels.first(where: { $0.id == tunnel.id }) ?? tunnel
    }

    private var isManaged: Bool {
        live.scope == .managed
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
        .onAppear { loadRule() }
        .onChange(of: live.autoConnectRule) { _, _ in loadRule() }
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

    private var showWiFiOptions: Bool {
        ruleEnabled && (ruleInterface == .wifi || ruleInterface == .both)
    }

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
            Toggle(isOn: $ruleEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable On-Demand")
                        .font(.subheadline.weight(.medium))
                    Text("Automatically connect or disconnect based on network conditions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(isManaged)
            .onChange(of: ruleEnabled) { _, _ in saveRule() }

            if ruleEnabled {
                Divider()

                Picker("Action", selection: $ruleAction) {
                    ForEach(AutoConnectAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isManaged)
                .onChange(of: ruleAction) { _, _ in saveRule() }

                Divider()

                HStack {
                    Text(ruleAction == .connect ? "Connect on" : "Disconnect on")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)

                    Picker("", selection: $ruleInterface) {
                        ForEach(AutoConnectInterface.allCases, id: \.self) { iface in
                            Text(iface.displayName).tag(iface)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(isManaged)
                    .onChange(of: ruleInterface) { _, _ in saveRule() }
                }

                if showWiFiOptions {
                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Wi-Fi Networks")
                            .font(.subheadline.weight(.medium))

                        Toggle("Any Wi-Fi Network", isOn: $ruleAnyWiFi)
                            .toggleStyle(.checkbox)
                            .disabled(isManaged)
                            .onChange(of: ruleAnyWiFi) { _, _ in
                                if ruleAnyWiFi { ruleSSIDs = [] }
                                saveRule()
                            }

                        if !ruleAnyWiFi {
                            // SSID list
                            if !ruleSSIDs.isEmpty {
                                VStack(spacing: 4) {
                                    ForEach(ruleSSIDs, id: \.self) { ssid in
                                        HStack {
                                            Image(systemName: "wifi")
                                                .foregroundStyle(.secondary)
                                                .font(.caption)
                                            Text(ssid)
                                                .font(.system(.subheadline, design: .monospaced))
                                            Spacer()
                                            Button {
                                                ruleSSIDs.removeAll { $0 == ssid }
                                                saveRule()
                                            } label: {
                                                Image(systemName: "minus.circle.fill")
                                                    .foregroundStyle(.red)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(isManaged)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.secondary.opacity(0.06),
                                                    in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }

                            // Add SSID field
                            HStack {
                                TextField("SSID name", text: $newSSID)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .onSubmit { addSSID() }
                                Button("Add") { addSSID() }
                                    .buttonStyle(.bordered)
                                    .disabled(isManaged ||
                                              newSSID.trimmingCharacters(in: .whitespaces).isEmpty ||
                                              ruleSSIDs.contains(newSSID.trimmingCharacters(in: .whitespaces)))
                            }

                            // Add current network shortcut
                            if let ssid = tunnelManager.networkMonitor.currentSSID {
                                Button {
                                    guard !ruleSSIDs.contains(ssid) else { return }
                                    ruleSSIDs.append(ssid)
                                    saveRule()
                                } label: {
                                    Label("Add Current: \"\(ssid)\"", systemImage: "wifi.circle")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isManaged || ruleSSIDs.contains(ssid))
                            }
                        }
                    }
                }

                // Status indicator
                Divider()
                HStack(spacing: 6) {
                    let matches = tunnelManager.networkMonitor.matchesTunnel(live)
                    Circle()
                        .fill(matches ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(matches ? "Current network matches rule" : "Current network does not match rule")
                        .font(.caption)
                        .foregroundStyle(matches ? .green : .secondary)
                }
            }
        }
    }

    // MARK: On-Demand Helpers

    private func loadRule() {
        let rule = live.autoConnectRule
        ruleEnabled   = rule.enabled
        ruleInterface = rule.interface
        ruleAction    = rule.action
        ruleAnyWiFi   = rule.matchesAnyWiFi
        ruleSSIDs     = rule.wifiSSIDs
        newSSID       = ""
    }

    private func saveRule() {
        guard !isManaged else { return }
        let rule = AutoConnectRule(
            enabled:   ruleEnabled,
            interface: ruleInterface,
            action:    ruleAction,
            wifiSSIDs: ruleAnyWiFi ? [] : ruleSSIDs
        )
        tunnelManager.updateAutoConnectRule(for: live, rule: rule)
    }

    private func addSSID() {
        let s = newSSID.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !ruleSSIDs.contains(s) else { return }
        ruleSSIDs.append(s)
        newSSID = ""
        saveRule()
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
