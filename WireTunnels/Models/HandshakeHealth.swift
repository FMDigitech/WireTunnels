import Foundation

/// Detects a tunnel that is up but never heard back from its server. WireGuard only starts a
/// handshake when it has something to send, and an idle tunnel has nothing to say, so "no
/// handshake" alone is normal. The tell-tale of a dead path is a tunnel that has sent bytes
/// (every handshake attempt counts) and never received one.
nonisolated enum HandshakeHealth {
    /// How long a new connection may take before silence counts. A handshake normally takes
    /// well under a second, and wireguard retries every five seconds.
    static let gracePeriod: TimeInterval = 25

    static func isUnanswered(isActive: Bool, connectedAt: Date?, lastHandshake: Date?,
                             rxBytes: Int64, txBytes: Int64, now: Date = Date()) -> Bool {
        guard isActive, lastHandshake == nil, rxBytes == 0, txBytes > 0 else { return false }
        // A tunnel adopted at launch has no connect time: its counters have run since it started.
        guard let connectedAt else { return true }
        return now.timeIntervalSince(connectedAt) >= gracePeriod
    }
}
