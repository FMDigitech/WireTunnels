import Combine
import Foundation

final class DashboardNavigation: ObservableObject {
    @Published private(set) var requestedTunnelID: UUID?

    func requestTunnel(_ tunnelID: UUID) {
        requestedTunnelID = tunnelID
    }

    /// A screen another view wants the dashboard to open (e.g. "Turn on monitoring…" → Settings).
    @Published private(set) var requestedSidebar: SidebarItem?

    func requestSidebar(_ item: SidebarItem) { requestedSidebar = item }
    func consumeSidebarRequest() { requestedSidebar = nil }

    func consumeRequest(_ tunnelID: UUID) {
        guard requestedTunnelID == tunnelID else { return }
        requestedTunnelID = nil
    }
}
