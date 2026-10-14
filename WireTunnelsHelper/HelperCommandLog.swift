import Foundation
import OSLog

struct HelperCommandEvent: Codable {
    let id: UUID
    let commandID: UUID
    let command: String
    let stage: String
    let elapsed: TimeInterval
    let exitCode: Int32?
    let timedOut: Bool
}

final class HelperCommandLog {
    static let shared = HelperCommandLog()
    private let lock = NSLock()
    private var events: [HelperCommandEvent] = []
    private let logger = Logger(subsystem: "com.fmdigitech.WireTunnels", category: "helper-command")

    func record(commandID: UUID, command: String, stage: String, elapsed: TimeInterval, exitCode: Int32? = nil, timedOut: Bool = false) {
        let event = HelperCommandEvent(id: UUID(), commandID: commandID, command: command, stage: stage, elapsed: elapsed, exitCode: exitCode, timedOut: timedOut)
        lock.lock()
        events.append(event)
        if events.count > 128 { events.removeFirst(events.count - 128) }
        lock.unlock()
        logger.notice("\(command, privacy: .public): \(stage, privacy: .public), elapsed=\(elapsed, privacy: .public)s")
    }

    func snapshot() -> [HelperCommandEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
