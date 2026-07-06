import SwiftUI
import OSLog
import ServiceManagement

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var updaterService: UpdaterService

    @AppStorage("launchAtLogin")     var launchAtLogin    = false
    @AppStorage("showNotifications") var showNotifications = false
    @AppStorage("showRawOutput")     var showRawOutput    = false

    @State private var showingResetConfirm = false
    @State private var isRedetecting = false
    @State private var isInstallingTools = false
    @ObservedObject private var logService: LogService = .shared
    private let notificationService = NotificationService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // MARK: WireGuard Tools
                SettingsSection(title: "WireGuard Tools", systemImage: "wrench.and.screwdriver") {
                    if let runtime = tunnelManager.environment.runtimeStatus {
                        RuntimeMetadataView(status: runtime)
                    } else if let bundled = tunnelManager.bundledRuntimeStatus {
                        RuntimeMetadataView(status: bundled)
                    }

                    Divider()

                    ToolPathRow(label: "wg", path: tunnelManager.environment.wgPath)
                    ToolPathRow(label: "wg-quick", path: tunnelManager.environment.wgQuickPath)
                    ToolPathRow(label: "wireguard-go", path: tunnelManager.environment.wireguardGoPath)

                    Divider()

                    HStack {
                        StatusIndicatorRow(
                            label: "Helper Tool",
                            isOK: tunnelManager.environment.helperInstalled,
                            okText: "Installed",
                            failText: "Not Installed"
                        )
                        Spacer()
                        StatusIndicatorRow(
                            label: "Binaries",
                            isOK: tunnelManager.environment.binariesInstalled,
                            okText: "Found",
                            failText: "Missing"
                        )
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if tunnelManager.isLoading {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Circle()
                                        .fill(tunnelManager.environment.isReady ? Color.green : Color.red)
                                        .frame(width: 8, height: 8)
                                }
                                Text(tunnelManager.isLoading
                                     ? (tunnelManager.setupStatus ?? "Setting up…")
                                     : (tunnelManager.environment.isReady ? "Environment Ready" : "Environment Not Ready"))
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(
                                        tunnelManager.isLoading ? .primary :
                                        (tunnelManager.environment.isReady ? Color.green : Color.red)
                                    )
                            }
                            if !tunnelManager.isLoading && !tunnelManager.environment.isReady {
                                Text("Installation uses verified tools bundled with the signed app. There is no download and no Homebrew dependency.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        HStack {
                            Button {
                                installTools()
                            } label: {
                                if isInstallingTools {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label(
                                        tunnelManager.environment.binariesInstalled
                                            ? "Reinstall Tools"
                                            : "Install Tools",
                                        systemImage: "shippingbox.and.arrow.backward"
                                    )
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isInstallingTools || tunnelManager.isLoading || tunnelManager.bundledRuntimeStatus?.isValid != true)

                            Button {
                                redetect()
                            } label: {
                                if isRedetecting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Re-detect", systemImage: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isRedetecting || isInstallingTools || tunnelManager.isLoading)
                        }
                    }

                    if tunnelManager.isLoading && !logService.logEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(logService.logEntries.suffix(6)) { entry in
                                Text(entry.line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }

                    if tunnelManager.helperRequiresApproval {
                        HStack {
                            Text("macOS requires approval before the privileged helper can run.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button {
                                tunnelManager.openHelperApprovalSettings()
                            } label: {
                                Label("Enable Helper", systemImage: "gear")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                // MARK: Config Storage
                SettingsSection(title: "Config Storage", systemImage: "folder") {
                    PathDisplayRow(label: "User Configs", path: AppPaths.userConfigDir.path)
                    PathDisplayRow(label: "Metadata", path: AppPaths.userMetadataDir.path)
                    PathDisplayRow(label: "Logs", path: AppPaths.userLogsDir.path)
                    PathDisplayRow(label: "Runtime Configs", path: AppPaths.runtimeConfigDir.path)

                    HStack {
                        Spacer()
                        Button {
                            NSWorkspace.shared.open(AppPaths.userRoot)
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                // MARK: Behavior
                SettingsSection(title: "Behavior", systemImage: "gearshape.2") {
                    Toggle(isOn: $launchAtLogin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")
                                .font(.body)
                            Text("Start WireGuard Tunnels automatically when you log in.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }

                    Divider()

                    Toggle(isOn: $showNotifications) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Notifications")
                                .font(.body)
                            Text("Notify when tunnels connect, disconnect, or encounter errors.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .onChange(of: showNotifications) { _, enabled in
                        Task {
                            let granted = await notificationService
                                .setNotificationsEnabled(enabled)
                            if enabled && !granted {
                                showNotifications = false
                            }
                        }
                    }
                }

                // MARK: Updates
                SettingsSection(title: "Updates", systemImage: "arrow.triangle.2.circlepath") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Check for Updates")
                                .font(.body)
                            Text("WireTunnels checks for updates automatically on launch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Check Now") {
                            updaterService.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!updaterService.canCheckForUpdates)
                    }
                }

                // MARK: Advanced
                SettingsSection(title: "Advanced", systemImage: "terminal") {
                    Toggle(isOn: $showRawOutput) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Raw wg Output")
                                .font(.body)
                            Text("Display raw command output in the Log view for debugging.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset App Data")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.red)
                            Text("Removes all tunnels, preferences, and cached data. This cannot be undone.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            showingResetConfirm = true
                        } label: {
                            Label("Reset…", systemImage: "exclamationmark.triangle")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Reset All App Data?",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                resetAppData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All tunnels and preferences will be permanently deleted.")
        }
        .task {
            guard showNotifications else { return }
            let granted = await notificationService.setNotificationsEnabled(true)
            if !granted {
                showNotifications = false
            }
        }
        .alert("WireTunnels Error", isPresented: managerErrorBinding) {
            Button("OK") {
                tunnelManager.errorMessage = nil
            }
        } message: {
            Text(tunnelManager.errorMessage ?? "")
        }
    }

    private func redetect() {
        isRedetecting = true
        Task {
            await tunnelManager.redetectEnvironment()
            isRedetecting = false
        }
    }

    private func installTools() {
        isInstallingTools = true
        Task {
            await tunnelManager.installBundledTools()
            isInstallingTools = false
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // SMAppService can fail if the app hasn't been launched from /Applications yet.
            // The @AppStorage value will still reflect intent; the user can retry by toggling.
            LogService.shared.error("Launch at login \(enabled ? "enable" : "disable") failed: \(error.localizedDescription)")
        }
    }

    private func resetAppData() {
        Task {
            try? await SMAppService.mainApp.unregister()
            guard await tunnelManager.resetUserData() else { return }
            launchAtLogin = false
            showNotifications = false
            showRawOutput = false
        }
    }

    private var managerErrorBinding: Binding<Bool> {
        Binding(
            get: { tunnelManager.errorMessage != nil },
            set: { isPresented in
                guard !isPresented else { return }
                tunnelManager.errorMessage = nil
            }
        )
    }
}

// MARK: - Log View

struct LogView: View {
    @ObservedObject var logService: LogService = .shared

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Application Log")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    logService.clearLog()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Clear all log entries")

                Button {
                    copyLogToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy log to clipboard")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if logService.logLines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No Log Entries")
                        .font(.headline)
                    Text("Activity will appear here as you use the app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(logService.logEntries) { entry in
                                LogLineView(line: entry.line)
                                    .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: logService.logEntries.count) { _, _ in
                        if let last = logService.logEntries.indices.last {
                            withAnimation {
                                proxy.scrollTo(logService.logEntries[last].id, anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        if let last = logService.logEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .navigationTitle("Log")
    }

    private func copyLogToClipboard() {
        let text = logService.logLines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Log Line View

private struct LogLineView: View {
    let line: String

    private var lineColor: Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("failed") { return .red }
        if lower.contains("warn")                               { return .orange }
        if lower.contains("connected") || lower.contains("success") { return .green }
        return .primary
    }

    var body: some View {
        Text(line)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(lineColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .textSelection(.enabled)
    }
}

// MARK: - Supporting Views

private struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct RuntimeMetadataView: View {
    let status: WireGuardRuntimeStatus

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PathDisplayRow(label: "Runtime", path: status.versionSummary)
            PathDisplayRow(label: "Source", path: status.source)
            PathDisplayRow(label: "Architecture", path: status.architectureSummary)
            PathDisplayRow(
                label: "Last verified",
                path: Self.dateFormatter.string(from: status.verifiedAt)
            )

            HStack(spacing: 6) {
                Image(systemName: status.isValid ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .foregroundStyle(status.isValid ? .green : .red)
                Text("SHA256: \(status.isValid ? "valid" : "invalid")")
                    .font(.subheadline.weight(.medium))
            }

            ForEach(status.artifacts) { artifact in
                HStack {
                    Text(artifact.name)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .frame(width: 100, alignment: .leading)
                    Text(artifact.revision)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: artifact.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(artifact.isValid ? .green : .red)
                }
            }

            if let error = status.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct ToolPathRow: View {
    let label: String
    let path: String?

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .frame(width: 120, alignment: .leading)

            if let path {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text("Not found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct StatusIndicatorRow: View {
    let label: String
    let isOK: Bool
    let okText: String
    let failText: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isOK ? .green : .red)
            Text("\(label): \(isOK ? okText : failText)")
                .font(.subheadline)
        }
    }
}

private struct PathDisplayRow: View {
    let label: String
    let path: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
