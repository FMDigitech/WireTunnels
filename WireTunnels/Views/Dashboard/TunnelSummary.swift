import SwiftUI

/// One-sentence state and total speed shown above the list on All Tunnels, Active, Shared and Favorites.
struct TunnelSummaryBanner: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var monitor: LinkQualityMonitor
    let filter: SidebarItem
    @State private var accounts: [MacAccount] = []

    /// Total speed of the connected tunnels. The exit leg of an active chain is skipped: its
    /// traffic already travels inside the entry tunnel, so adding both would count it twice.
    private var speeds: (down: Double, up: Double)? { tunnelManager.totalSpeedMbps }

    private var scoped: [Tunnel] {
        switch filter {
        case .active: return tunnelManager.tunnels.filter(\.isActive)
        case .shared: return tunnelManager.sharedTunnels
        case .favorites: return tunnelManager.favoriteTunnels
        default: return tunnelManager.tunnels
        }
    }

    private var summary: (tone: StatusTone, title: String, detail: String) {
        let tunnels = scoped
        let connected = tunnels.filter(\.isActive)
        let offline = tunnels.filter { !$0.isActive }
        let poor = connected.filter { monitor.quality(for: $0) == .poor }.map(\.name)
        let fair = connected.filter { monitor.quality(for: $0) == .fair }.map(\.name)
        let broken = tunnelManager.activeWarnings.contains { if case .noHandshake = $0 { return true } else { return false } }
        let offlineNote = offline.isEmpty ? "" : " · \(offline.prefix(2).map(\.name).joined(separator: ", ")) \(offline.count == 1 ? "is" : "are") not connected"

        switch filter {
        case .active:
            if connected.isEmpty { return (.neutral, "No tunnel is active", "Connect a tunnel to see its session here.") }
            let longest = connected.compactMap { t in t.connectedAt.map { (t.name, $0) } }.min { $0.1 < $1.1 }
            let reconnects = monitor.events.filter { $0.kind == .reconnect && $0.time > Date().addingTimeInterval(-900) }.count
            var parts: [String] = []
            if let longest { parts.append("Longest session \(Format.duration(since: longest.1)) (\(longest.0))") }
            if reconnects > 0 { parts.append("\(reconnects) automatic reconnect\(reconnects == 1 ? "" : "s") in the last 15 min") }
            let tone: StatusTone = !poor.isEmpty || broken ? .bad : (!fair.isEmpty ? .warn : .good)
            return (tone, "\(connected.count) tunnel\(connected.count == 1 ? "" : "s") active", parts.joined(separator: " · "))
        case .shared:
            let accountNote = accounts.isEmpty ? "" : " · \(accounts.filter { $0.state.isSignedIn }.count) accounts signed in on this Mac"
            if tunnels.isEmpty { return (.neutral, "No shared tunnels", "Share a tunnel to make it available to every account on this Mac.") }
            let tone: StatusTone = !poor.isEmpty || broken ? .bad : (!fair.isEmpty ? .warn : (connected.isEmpty ? .neutral : .good))
            let title = tone == .good ? "Shared tunnels are working" : (connected.isEmpty ? "No shared tunnel is connected" : "A shared tunnel needs attention")
            return (tone, title, "\(connected.count) of \(tunnels.count) shared tunnels connected\(accountNote)")
        case .favorites:
            if tunnels.isEmpty { return (.neutral, "No favorites yet", "Star a tunnel to keep it one click away.") }
            let tone: StatusTone = !poor.isEmpty || broken ? .bad : (!fair.isEmpty ? .warn : (connected.isEmpty ? .neutral : .good))
            return (tone, "\(connected.count) of \(tunnels.count) favorites connected", offline.isEmpty ? "All your favorites are connected." : "Not connected: \(offline.map(\.name).joined(separator: ", "))")
        default:
            if tunnels.isEmpty { return (.info, "No tunnels yet", "Import a .conf file or create a tunnel to get started.") }
            if connected.isEmpty { return (.neutral, "Nothing is connected", "\(tunnels.count) tunnel\(tunnels.count == 1 ? "" : "s") available. Connect one to start.") }
            if !poor.isEmpty || broken {
                let names = poor.isEmpty ? "A tunnel" : poor.joined(separator: ", ")
                return (.bad, "\(names) has a problem", "\(connected.count) of \(tunnels.count) tunnels connected · open Warnings or the tunnel for details")
            }
            // A note (severity info, e.g. different DNS servers) does not change "everything is working".
            if !fair.isEmpty || tunnelManager.activeWarnings.contains(where: { $0.severity != .info }) {
                return (.warn, "Working, with something to look at", "\(connected.count) of \(tunnels.count) tunnels connected\(offlineNote)")
            }
            return (.good, "Everything is working", "\(connected.count) of \(tunnels.count) tunnels connected\(offlineNote)")
        }
    }

    var body: some View {
        let s = summary
        SummaryBanner(tone: s.tone, title: s.title, detail: s.detail) {
            SpeedFigures(caption: "Total speed, connected tunnels · now", downMbps: speeds?.down, upMbps: speeds?.up)
        }
        .task(id: filter) {
            guard filter == .shared else { return }
            accounts = await Task.detached { MacAccountsService.load() }.value
        }
    }
}
