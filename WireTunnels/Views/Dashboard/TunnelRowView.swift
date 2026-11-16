import SwiftUI

/// Column widths shared by the list header and every row, so they always line up.
enum TunnelColumns {
    static let state: CGFloat = 104
    static let session: CGFloat = 64
    static let speed: CGFloat = 88
    static let quality: CGFloat = 70
    static let action: CGFloat = 76
}

struct TunnelRowView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var dashboardNavigation: DashboardNavigation
    @EnvironmentObject var monitor: LinkQualityMonitor
    let tunnel: Tunnel
    var filter: SidebarItem = .all
    /// Accounts with a login session on this Mac, shown on shared tunnels.
    var signedInCount: Int?
    @State private var isProcessing = false
    @Environment(\.masterIsCompact) private var compact

    private var rates: (down: Double, up: Double)? {
        guard tunnel.isActive, let last = tunnelManager.trafficHistory[tunnel.id]?.last else { return nil }
        return (last.rxRate * 8 / 1_000_000, last.txRate * 8 / 1_000_000)
    }

    private var hasWarning: Bool {
        tunnelManager.activeWarnings.contains { warning in
            switch warning {
            case .multipleFullTunnels(let names):       return names.contains(tunnel.name)
            case .overlappingAllowedIPs(let a, let b):  return a == tunnel.name || b == tunnel.name
            case .conflictingDNS(let names):            return names.contains(tunnel.name)
            case .killSwitchBlocking(let name):         return name == tunnel.name
            case .ipFamilyLeak(let name, _):            return name == tunnel.name
            case .noHandshake(let name, _):             return name == tunnel.name
            }
        }
    }

    private var chainRole: String? {
        guard let chain = tunnelManager.hopChains.first(where: { $0.hopTunnelID == tunnel.id || $0.exitTunnelID == tunnel.id }) else { return nil }
        return chain.hopTunnelID == tunnel.id ? "Chain · entry" : "Chain · exit"
    }

    private var state: (text: String, tone: StatusTone) {
        switch tunnelManager.connectionStatus(for: tunnel) {
        case .connecting: return ("Connecting", .info)
        case .reconnecting: return ("Reconnecting", .warn)
        case .connectionLost: return ("Connection lost", .bad)
        default:
            // A warning is flagged by the triangle next to the name; it does not change the state.
            return tunnel.isActive ? ("Connected", .good) : ("Not connected", .neutral)
        }
    }

    private var connectionBinding: Binding<Bool> {
        Binding(
            get: { tunnel.isActive },
            set: { shouldConnect in
                guard shouldConnect != tunnel.isActive, !isProcessing else { return }
                isProcessing = true
                Task {
                    if shouldConnect {
                        await tunnelManager.connectTunnel(tunnel)
                    } else {
                        await tunnelManager.disconnectTunnel(tunnel)
                    }
                    isProcessing = false
                }
            }
        )
    }

    private var connectionDisabled: Bool {
        isProcessing
            || tunnelManager.isShuttingDown
            || tunnelManager.connectionStatus(for: tunnel) == .connecting
            || tunnelManager.connectionStatus(for: tunnel) == .reconnecting
            || (!tunnel.isActive && !tunnelManager.canConnectTunnels)
            || (tunnel.scope == .managed && tunnel.isActive && tunnel.managedPolicy?.usersCanDisconnect == false)
            || (tunnel.scope == .managed && !tunnel.isActive && tunnel.managedPolicy?.usersCanConnect == false)
    }

    var body: some View {
        Group {
            if compact { compactBody } else { wideBody }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu { menuItems }
    }

    /// Narrow list: the name gets the whole first line, state and speed sit below it.
    private var compactBody: some View {
        let s = state
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if tunnel.isFavorite {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).accessibilityLabel("Favorite")
                }
                Text(tunnel.name).font(.body.weight(.semibold)).lineLimit(1)
                if hasWarning {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                        .accessibilityLabel("Has a warning")
                }
                Spacer(minLength: 6)
                QualityBadge(level: monitor.quality(for: tunnel))
                if filter == .favorites {
                    Button(tunnel.isActive ? "Disconnect" : "Connect") { connectionBinding.wrappedValue = !tunnel.isActive }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(connectionDisabled)
                }
            }
            if let endpoint = tunnel.endpoint, !endpoint.isEmpty {
                Text(endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    if isProcessing { ProgressView().scaleEffect(0.5).frame(width: 10, height: 10) }
                    else { Image(systemName: s.tone.icon).font(.caption2).foregroundStyle(s.tone.color) }
                    Text(s.text).font(.callout).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                if let rates {
                    Text("↓ \(Format.mbps(rates.down))  ↑ \(Format.mbps(rates.up))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            FlowLayout(spacing: 4) {
                if tunnel.scope == .managed {
                    chip(signedInCount.map { "Shared · \($0) signed in" } ?? "Shared", systemImage: "lock.fill")
                }
                if let chainRole { chip(chainRole) }
                if tunnel.engine == .amneziaWG { chip(tunnel.engine.displayName) }
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if tunnel.scope == .personal {
            Button {
                tunnelManager.toggleFavorite(tunnel)
            } label: {
                Label(tunnel.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: tunnel.isFavorite ? "star.slash" : "star")
            }
            Button {
                do {
                    let copy = try tunnelManager.duplicateTunnel(tunnel)
                    dashboardNavigation.requestTunnel(copy.id)
                } catch {
                    tunnelManager.errorMessage = error.localizedDescription
                }
            } label: {
                Label("Duplicate Tunnel", systemImage: "doc.on.doc")
            }
        }
    }

    private var wideBody: some View {
        let s = state
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if tunnel.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                    Text(tunnel.name).font(.body.weight(.semibold)).lineLimit(1)
                    if hasWarning {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                            .accessibilityLabel("Has a warning")
                    }
                }
                if let endpoint = tunnel.endpoint, !endpoint.isEmpty {
                    Text(endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    if tunnel.scope == .managed {
                        chip(signedInCount.map { "Shared · \($0) signed in" } ?? "Shared", systemImage: "lock.fill")
                    }
                    if let chainRole { chip(chainRole) }
                    if tunnel.engine == .amneziaWG { chip(tunnel.engine.displayName) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                if isProcessing { ProgressView().scaleEffect(0.5).frame(width: 10, height: 10) }
                else { Image(systemName: s.tone.icon).font(.caption2).foregroundStyle(s.tone.color) }
                Text(s.text).font(.callout).lineLimit(1)
            }
            .frame(width: TunnelColumns.state, alignment: .leading)
            .accessibilityElement(children: .combine)

            if filter == .active && !compact {
                Text(tunnel.connectedAt.map { Format.duration(since: $0) } ?? "—")
                    .font(.callout.monospacedDigit()).frame(width: TunnelColumns.session, alignment: .leading)
                Text(tunnel.lastHandshake.map { Format.duration(since: $0) + " ago" } ?? "—")
                    .font(.callout.monospacedDigit()).frame(width: TunnelColumns.session + 14, alignment: .leading)
            }

            Group {
                if let rates {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("↓ \(Format.mbps(rates.down))")
                        Text("↑ \(Format.mbps(rates.up))")
                    }
                    .font(.caption.monospacedDigit())
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .frame(width: TunnelColumns.speed, alignment: .leading)
            .accessibilityLabel(rates.map { "Download \(Format.mbps($0.down)), upload \(Format.mbps($0.up))" } ?? "No speed")

            QualityBadge(level: monitor.quality(for: tunnel))
                .frame(width: TunnelColumns.quality, alignment: .leading)

            if filter == .favorites {
                Button(tunnel.isActive ? "Disconnect" : "Connect") { connectionBinding.wrappedValue = !tunnel.isActive }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(connectionDisabled)
                    .frame(width: TunnelColumns.action + 18)
            } else if !compact && filter != .active {
                Toggle(isOn: connectionBinding) { Text("Connection") }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(connectionDisabled)
                    .help(tunnel.isActive ? "Disconnect \(tunnel.name)" : (tunnelManager.connectionUnavailableReason ?? "Connect \(tunnel.name)"))
                    .accessibilityLabel("Connection for \(tunnel.name)")
            }
        }
    }

    private func chip(_ text: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 8)) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
