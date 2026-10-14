import Foundation

enum TunnelConnectionStatus: Equatable {
    case idle, connected, connecting, reconnecting, connectionLost

    var systemImage: String {
        switch self {
        case .idle: return "network.slash"
        case .connected: return "network"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .connectionLost: return "exclamationmark.circle"
        }
    }

    var description: String {
        switch self {
        case .idle: return "No tunnels connected"
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .reconnecting: return "Reconnecting..."
        case .connectionLost: return "Connection lost"
        }
    }

    func menuBarImage(hasWarnings: Bool, hasError: Bool) -> String {
        if hasError { return "exclamationmark.octagon" }
        switch self {
        case .connecting, .reconnecting, .connectionLost: return systemImage
        case .idle, .connected:
            return hasWarnings ? "exclamationmark.triangle" : systemImage
        }
    }
}

/// Keeps background connection feedback separate from alerts for user actions.
struct TunnelConnectionFeedback {
    private var activity: [UUID: TunnelConnectionStatus] = [:]
    private(set) var issues: [UUID: String] = [:]

    mutating func begin(_ id: UUID, reconnecting: Bool) {
        activity[id] = reconnecting ? .reconnecting : .connecting
    }

    mutating func finish(_ id: UUID) {
        activity.removeValue(forKey: id)
    }

    mutating func connected(_ id: UUID) {
        issues.removeValue(forKey: id)
    }

    mutating func completeConnection(_ id: UUID, isActive: Bool) {
        if isActive { connected(id) }
        else { lost(id) }
    }

    mutating func disconnected(_ id: UUID) {
        issues.removeValue(forKey: id)
    }

    mutating func lost(_ id: UUID) {
        issues[id] = "Connection lost"
    }

    /// The caller logs every failure, but only user actions produce an alert.
    @discardableResult
    mutating func failed(_ id: UUID, message: String, automatic: Bool) -> String? {
        issues[id] = message
        return automatic ? nil : message
    }

    func status(for id: UUID) -> TunnelConnectionStatus? {
        activity[id] ?? (issues[id] == nil ? nil : .connectionLost)
    }

    func menuBarStatus(hasActiveTunnels: Bool) -> TunnelConnectionStatus {
        if activity.values.contains(.reconnecting) { return .reconnecting }
        if !activity.isEmpty { return .connecting }
        if !issues.isEmpty { return .connectionLost }
        return hasActiveTunnels ? .connected : .idle
    }

    mutating func retain(tunnelIDs: Set<UUID>) {
        activity = activity.filter { tunnelIDs.contains($0.key) }
        issues = issues.filter { tunnelIDs.contains($0.key) }
    }
}
