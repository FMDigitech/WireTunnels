import Combine
import Foundation

final class DashboardNavigation: ObservableObject {
    @Published private(set) var requestedTunnelID: UUID?

    func requestTunnel(_ tunnelID: UUID) {
        requestedTunnelID = tunnelID
    }

    func consumeRequest(_ tunnelID: UUID) {
        guard requestedTunnelID == tunnelID else { return }
        requestedTunnelID = nil
    }
}
