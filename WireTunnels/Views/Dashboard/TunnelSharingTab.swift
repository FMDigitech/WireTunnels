import SwiftUI

/// Sharing tab: a shared tunnel is available to every account on this Mac, and only an
/// administrator can change that. There are no per-user permissions to show.
struct TunnelSharingTab: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var monitor: LinkQualityMonitor
    let tunnel: Tunnel
    let canShare: Bool
    let onMakeShared: () -> Void
    @State private var accounts: [MacAccount] = []
    @State private var loaded = false
    @State private var lastUpdated = Date()

    private var isShared: Bool { tunnel.scope == .managed }
    private var signedIn: [MacAccount] { accounts.filter { $0.state.isSignedIn } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isShared {
                sharedBody
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        PaneSectionHeader(title: "Personal tunnel", note: "Only you can see and use this tunnel.")
                        Text("Sharing makes it available to every account on this Mac, and an administrator approves the change. It is local to this Mac: nothing goes to the cloud.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button {
                            onMakeShared()
                        } label: {
                            Label("Share Tunnel…", systemImage: "person.2.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canShare)
                        if tunnel.isActive {
                            Text("Disconnect the tunnel before sharing it.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task(id: tunnel.id) { await reload() }
    }

    @ViewBuilder
    private var sharedBody: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    PaneSectionHeader(title: "Signed in on this Mac", note: "Accounts that have a login session. Shared on this Mac only.")
                    Spacer()
                    StatusPill(text: "Live", tone: .good)
                    Text("Updated \(Format.clock(lastUpdated))").font(.caption).foregroundStyle(.secondary)
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh the account list")
                }
                if tunnel.isActive {
                    Text("Tunnel is on · \(signedIn.count) \(signedIn.count == 1 ? "user is" : "users are") signed in" + (tunnel.connectedAt.map { " · connected \(Format.duration(since: $0)) ago" } ?? ""))
                        .font(.callout.weight(.medium))
                    Text("Turning the tunnel off turns it off for every account that is using it. (Assumption to confirm: other accounts are not asked.)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Tunnel is off. It is still shared with every account on this Mac.").font(.callout.weight(.medium))
                }
                if !loaded {
                    ProgressView().controlSize(.small)
                } else if accounts.isEmpty {
                    Notice(tone: .warn, title: "Could not read the account list",
                           message: "The Mac's directory did not answer. Try Refresh.")
                }
                ForEach(accounts) { account in
                    HStack(spacing: 10) {
                        Text(String(account.name.prefix(2)).uppercased())
                            .font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor.opacity(0.14), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.isCurrentUser ? "You" : account.name).font(.callout.weight(.semibold))
                            Text(account.isCurrentUser ? account.name : "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(text: account.state.label, tone: account.state.isSignedIn ? .good : .neutral)
                        Text(account.roleLabel).font(.caption).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                    }
                }
            }
        }

        Card {
            VStack(alignment: .leading, spacing: 6) {
                PaneSectionHeader(title: "Who can change it")
                Text(tunnelManager.currentUserIsAdministrator
                     ? "You are an administrator: you can edit, replace or delete this tunnel and set what other users may do."
                     : "Only an administrator can change this tunnel's sharing, configuration or access rules. You can use it according to the rules below.")
                    .font(.callout).foregroundStyle(.secondary)
                let policy = tunnel.managedPolicy ?? ManagedTunnelPolicy()
                InfoRow(label: "Users can connect", value: policy.usersCanConnect ? "Yes" : "No")
                InfoRow(label: "Users can disconnect", value: policy.usersCanDisconnect ? "Yes" : "No")
            }
        }

        Card {
            VStack(alignment: .leading, spacing: 8) {
                PaneSectionHeader(title: "Recent activity", note: "Per-account traffic cannot be measured, so none is shown.")
                let events = Array(monitor.events(for: tunnel.id).filter { $0.kind != .handshake }.prefix(6))
                if events.isEmpty { Text("No events yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(events) { event in
                    HStack {
                        Text(Format.clock(event.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        Text(event.kind.rawValue).font(.callout.weight(.medium))
                        Text(event.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func reload() async {
        accounts = await Task.detached { MacAccountsService.load() }.value
        loaded = true
        lastUpdated = Date()
    }
}
