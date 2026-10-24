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
    /// Set for helper messages outside a command run, like tool reinstalls; nil for command stages.
    var message: String? = nil
    var isError: Bool? = nil
}

final class HelperCommandLog {
    static let shared = HelperCommandLog()
    private let lock = NSLock()
    private var events: [HelperCommandEvent] = []
    private let logger = Logger(subsystem: "com.fmdigitech.WireTunnels", category: "helper-command")

    func record(commandID: UUID, command: String, stage: String, elapsed: TimeInterval, exitCode: Int32? = nil, timedOut: Bool = false) {
        let event = HelperCommandEvent(id: UUID(), commandID: commandID, command: command, stage: stage, elapsed: elapsed, exitCode: exitCode, timedOut: timedOut)
        append(event)
        logger.notice("\(command, privacy: .public): \(stage, privacy: .public), elapsed=\(elapsed, privacy: .public)s")
    }

    /// Passes a message to the app's log with the next diagnostics read. The caller logs it to the system log.
    func recordMessage(_ message: String, isError: Bool) {
        append(HelperCommandEvent(id: UUID(), commandID: UUID(), command: "", stage: "", elapsed: 0, exitCode: nil,
                                  timedOut: false, message: message, isError: isError))
    }

    private func append(_ event: HelperCommandEvent) {
        lock.lock()
        events.append(event)
        if events.count > 128 { events.removeFirst(events.count - 128) }
        lock.unlock()
    }

    func snapshot() -> [HelperCommandEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
