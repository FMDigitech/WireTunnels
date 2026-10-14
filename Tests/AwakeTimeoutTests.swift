import Foundation

@main
struct AwakeTimeoutTests {
    @MainActor static func main() async throws {
        // A timer scheduled before sleep can resume after wake without its
        // requested amount of awake time having elapsed.
        var uptime = 100.0
        var waits: [UInt64] = []
        try await AwakeTimeout.wait(nanoseconds: 30_000_000_000, uptime: { uptime }, sleep: { duration in
            waits.append(duration)
            uptime += waits.count == 1 ? 0.5 : 29.5
        })
        guard uptime >= 130, waits.count == 2,
              waits[1] == 29_500_000_000 else {
            print("FAIL: helper timeout fired after sleep with less than 30 seconds of awake time")
            exit(1)
        }

        var zeroWaits = 0
        try await AwakeTimeout.wait(nanoseconds: 0, uptime: { 0 }, sleep: { _ in zeroWaits += 1 })
        guard zeroWaits == 0 else { fatalError("Already expired timeout slept again") }

        let started = ProcessInfo.processInfo.systemUptime
        try await AwakeTimeout.wait(nanoseconds: 20_000_000)
        guard ProcessInfo.processInfo.systemUptime - started >= 0.02 else {
            fatalError("A genuinely unresponsive helper lost its timeout")
        }

        let cancelled = Task { @MainActor in
            try await AwakeTimeout.wait(nanoseconds: 60_000_000_000)
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            fatalError("Cancelled timeout still fired")
        } catch is CancellationError { }
        print("PASS: helper deadlines exclude sleep, expire during awake time, and respect cancellation")
    }
}
