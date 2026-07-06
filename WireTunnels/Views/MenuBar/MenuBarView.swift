import SwiftUI
import AppKit
import Charts

struct MenuBarView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var dashboardNavigation: DashboardNavigation
    @Environment(\.openWindow) var openWindow

    private var activeTunnels: [Tunnel] {
        tunnelManager.tunnels.filter { $0.isActive }
    }

    private var inactiveTunnels: [Tunnel] {
        tunnelManager.tunnels.filter { !$0.isActive }
    }

    private var hasInactiveFavorites: Bool {
        tunnelManager.favoriteTunnels.contains { !$0.isActive }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header row with app name and warning badge
            HStack {
                Text("WireTunnels")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                Spacer()

                if !tunnelManager.activeWarnings.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        Text("\(tunnelManager.activeWarnings.count)")
                            .font(.caption.bold())
                            .foregroundStyle(.yellow)
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                }
            }

            Divider()
                .padding(.vertical, 2)

            // Connected section
            if !activeTunnels.isEmpty {
                SectionHeader(title: "Connected")

                let showCharts = activeTunnels.count <= 2
                ForEach(activeTunnels) { tunnel in
                    if showCharts {
                        TunnelMenuRowWithChart(
                            tunnel: tunnel,
                            samples: tunnelManager.trafficHistory[tunnel.id] ?? [],
                            detailAction: { openDashboard(tunnelID: tunnel.id) }
                        ) {
                            Task { await tunnelManager.disconnectTunnel(tunnel) }
                        }
                    } else {
                        TunnelMenuRow(
                            tunnel: tunnel,
                            isActive: true,
                            detailAction: { openDashboard(tunnelID: tunnel.id) }
                        ) {
                            Task { await tunnelManager.disconnectTunnel(tunnel) }
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 2)
            }

            // Disconnected section
            if !inactiveTunnels.isEmpty {
                SectionHeader(title: "Disconnected")

                ForEach(inactiveTunnels) { tunnel in
                    TunnelMenuRow(
                        tunnel: tunnel,
                        isActive: false,
                        detailAction: { openDashboard(tunnelID: tunnel.id) }
                    ) {
                        Task { await tunnelManager.connectTunnel(tunnel) }
                    }
                }

                Divider()
                    .padding(.vertical, 2)
            }

            // Empty state
            if tunnelManager.tunnels.isEmpty {
                Text("No tunnels configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                Divider()
                    .padding(.vertical, 2)
            }

            // Bulk actions
            if hasInactiveFavorites {
                MenuActionButton(label: "Start Favorites", systemImage: "star.fill") {
                    Task { await tunnelManager.startAllFavorites() }
                }
            }

            if tunnelManager.hasActiveTunnels {
                MenuActionButton(label: "Stop All", systemImage: "stop.circle", role: .destructive) {
                    Task { await tunnelManager.stopAllActive() }
                }
            }

            Divider()
                .padding(.vertical, 2)

            // Navigation actions
            MenuActionButton(label: "Open Dashboard", systemImage: "gauge.with.dots.needle.33percent") {
                openDashboard()
            }

            SettingsLink {
                MenuActionLabel(label: "Settings", systemImage: "gear")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.vertical, 2)

            MenuActionButton(label: "Quit", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }

            // Loading indicator at bottom
            if tunnelManager.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Updating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
        .frame(width: 300)
        .padding(.bottom, 4)
        .alert("WireTunnels Error", isPresented: managerErrorBinding) {
            Button("OK") {
                tunnelManager.errorMessage = nil
            }
        } message: {
            Text(tunnelManager.errorMessage ?? "")
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

    private func openDashboard(tunnelID: UUID? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "dashboard")
        if let tunnelID {
            dashboardNavigation.requestTunnel(tunnelID)
        }
        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.title == "WireTunnels" }
                .forEach {
                    $0.deminiaturize(nil)
                    $0.makeKeyAndOrderFront(nil)
                }
        }
    }
}

// MARK: - Helpers

private func networksLabel(for tunnel: Tunnel) -> String {
    let ips = tunnel.allowedIPs
    guard !ips.isEmpty else { return "" }
    let full = ips.contains("0.0.0.0/0")
    let full6 = ips.contains("::/0")
    if full && full6 { return "All traffic (IPv4+IPv6)" }
    if full { return "All traffic" }
    if ips.count == 1 { return ips[0] }
    if ips.count == 2 { return ips.joined(separator: ", ") }
    return "\(ips[0]) +\(ips.count - 1) more"
}

private func tunnelInfoLine(for tunnel: Tunnel) -> String {
    var parts: [String] = []
    if let firstAddr = tunnel.address?.first { parts.append(firstAddr) }
    let nets = networksLabel(for: tunnel)
    if !nets.isEmpty { parts.append(nets) }
    if let connectedAt = tunnel.connectedAt {
        parts.append("⏱ \(formatDuration(since: connectedAt))")
    }
    return parts.joined(separator: " · ")
}

// MARK: - Supporting Views

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

private struct TunnelMenuRow: View {
    let tunnel: Tunnel
    let isActive: Bool
    let detailAction: () -> Void
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isActive ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)

                Text(tunnel.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: detailAction) {
                    Label("Open Details", systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Open details for \(tunnel.name)")
                .accessibilityLabel("Open Details for \(tunnel.name)")

                Toggle(isOn: Binding(
                    get: { isActive },
                    set: { newValue in
                        if newValue != isActive {
                            action()
                        }
                    }
                )) {
                    Text("Connection")
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Connection for \(tunnel.name)")
            }

            if isActive {
                let info = tunnelInfoLine(for: tunnel)
                if !info.isEmpty {
                    Text(info)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 16)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct TunnelMenuRowWithChart: View {
    let tunnel: Tunnel
    let samples: [TrafficSample]
    let detailAction: () -> Void
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Name row
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text(tunnel.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(action: detailAction) {
                    Label("Open Details", systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Open details for \(tunnel.name)")
                .accessibilityLabel("Open Details for \(tunnel.name)")
                Toggle(isOn: Binding(
                    get: { true },
                    set: { isConnected in
                        if !isConnected {
                            action()
                        }
                    }
                )) {
                    Text("Connection")
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Connection for \(tunnel.name)")
            }

            // Info: own IP · networks · duration
            let info = tunnelInfoLine(for: tunnel)
            if !info.isEmpty {
                Text(info)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 16)
            }

            if !samples.isEmpty {
                // RX row
                HStack(spacing: 6) {
                    sparkline(samples.map(\.rxRate), color: .green)
                        .frame(width: 80, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("↓ \(formatBytes(Int64(samples.last?.rxRate ?? 0)))/s")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.green)
                        Text(formatBytes(tunnel.rxBytes) + " total")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }

                // TX row
                HStack(spacing: 6) {
                    sparkline(samples.map(\.txRate), color: .blue)
                        .frame(width: 80, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("↑ \(formatBytes(Int64(samples.last?.txRate ?? 0)))/s")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.blue)
                        Text(formatBytes(tunnel.txBytes) + " total")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func sparkline(_ values: [Double], color: Color) -> some View {
        let indexed = Array(values.enumerated())
        Chart(indexed, id: \.offset) { i, v in
            AreaMark(x: .value("i", i), y: .value("v", v))
                .foregroundStyle(color.opacity(0.2))
            LineMark(x: .value("i", i), y: .value("v", v))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

private struct MenuActionButton: View {
    let label: String
    let systemImage: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            MenuActionLabel(label: label, systemImage: systemImage)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuActionLabel: View {
    let label: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
            Text(label)
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
