import Foundation

/// A helper deadline must not count time when the Mac and helper are asleep.
@MainActor
enum AwakeTimeout {
    static func wait(
        nanoseconds: UInt64,
        uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws {
        let deadline = uptime() + Double(nanoseconds) / 1_000_000_000
        while true {
            try Task.checkCancellation()
            let remaining = deadline - uptime()
            guard remaining > 0 else { return }
            // Recheck uptime after every resume. Task.sleep can complete during
            // system sleep even though the helper had no opportunity to reply.
            try await sleep(UInt64(remaining * 1_000_000_000))
        }
    }
}
