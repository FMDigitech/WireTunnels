import Foundation

@main
struct HandshakeHealthTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func stuck(active: Bool = true, age: TimeInterval? = 60, handshake: Date? = nil,
                   rx: Int64 = 0, tx: Int64 = 2176) -> Bool {
            HandshakeHealth.isUnanswered(isActive: active, connectedAt: age.map { now.addingTimeInterval(-$0) },
                                         lastHandshake: handshake, rxBytes: rx, txBytes: tx, now: now)
        }
        expect(stuck(), "a tunnel that sent bytes and never got one back must be reported")
        expect(!stuck(age: 5), "a tunnel that has only just connected is given time")
        expect(!stuck(age: HandshakeHealth.gracePeriod - 1), "the grace period must hold until it ends")
        expect(stuck(age: HandshakeHealth.gracePeriod), "the grace period must end")
        expect(!stuck(tx: 0), "an idle tunnel has nothing to hand-shake over: not a fault")
        expect(!stuck(handshake: now.addingTimeInterval(-3)), "a tunnel that handshook is fine")
        expect(!stuck(rx: 148), "a tunnel that received something is fine")
        expect(!stuck(active: false), "a tunnel that is down is not reported")
        expect(stuck(age: nil), "a tunnel adopted at launch has no connect time, and is judged by its counters")
        print("PASS: an unanswered tunnel is reported only after the grace period, and only if it sent data")
    }
}
