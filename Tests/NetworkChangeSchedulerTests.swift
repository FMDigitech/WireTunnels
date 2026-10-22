import Foundation

@MainActor
private final class ReconnectGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class NetworkFixture {
    let gate = ReconnectGate()
    let allowedPrefix = "192.0.2."
    var address = "192.0.2.10"
    var active = true
    var autoOwned = true
    var reconnecting = false
    var evaluations = 0
    var evaluationsWhileReconnecting = 0
    var reconnects = 0
    var concurrentReconnects = 0
    var maximumConcurrentReconnects = 0

    func evaluateRules() async {
        evaluations += 1
        if reconnecting { evaluationsWhileReconnecting += 1 }
        guard !address.hasPrefix(allowedPrefix), active, autoOwned else { return }
        // Reproduce the manager's ownership bookkeeping and busy disconnect guard.
        autoOwned = false
        if !reconnecting { active = false }
    }

    func reconnect() async {
        guard active, !reconnecting else { return }
        reconnects += 1
        concurrentReconnects += 1
        maximumConcurrentReconnects = max(maximumConcurrentReconnects, concurrentReconnects)
        reconnecting = true
        await gate.wait()
        reconnecting = false
        concurrentReconnects -= 1
    }
}

@main
struct NetworkChangeSchedulerTests {
    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    @MainActor
    static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        expect(false, message)
    }

    @MainActor
    static func main() async throws {
        try await networkChangeDuringReconnect()
        try await evaluateBeforeReconnect()
        try await coalescePendingEvents()
        try await coalesceEventsDuringReconnect()
        try await cancelAndScheduleWhileDraining()
        try await cancelDuringRuleEvaluation()
        try await cancelPendingDebounce()
        print("PASS: network changes serialize rules and reconnects, coalesce events, and drain cancellation")
    }

    @MainActor
    static func networkChangeDuringReconnect() async throws {
        let fixture = NetworkFixture()
        let scheduler = NetworkChangeScheduler(debounceNanoseconds: 1_000_000,
            evaluateRules: { await fixture.evaluateRules() },
            reconnect: { await fixture.reconnect() })
        scheduler.schedule(addressChanged: true)
        try await waitUntil("the initial renewal never started reconnecting") { fixture.reconnecting }
        fixture.address = "198.51.100.20"
        scheduler.schedule(addressChanged: true)
        // Give an independent debounce task time to expose the original race.
        try await Task.sleep(nanoseconds: 10_000_000)
        fixture.gate.release()
        try await waitUntil("queued network changes never drained") { !scheduler.isProcessing }
        expect(!fixture.active, "leaving the allowed physical network during reconnect must disconnect the tunnel")
        expect(fixture.evaluationsWhileReconnecting == 0, "rule evaluation must wait for an in-flight reconnect")
        expect(fixture.reconnects == 1 && fixture.maximumConcurrentReconnects == 1,
            "a queued address change must not restart a tunnel that no longer matches")
    }

    @MainActor
    static func evaluateBeforeReconnect() async throws {
        let fixture = NetworkFixture()
        fixture.address = "198.51.100.20"
        let scheduler = NetworkChangeScheduler(debounceNanoseconds: 0,
            evaluateRules: { await fixture.evaluateRules() },
            reconnect: { await fixture.reconnect() })
        scheduler.schedule(addressChanged: true)
        try await waitUntil("an unmatched tunnel was restarted before its rule was evaluated") { !scheduler.isProcessing }
        expect(!fixture.active && fixture.reconnects == 0,
            "rule evaluation must disconnect an unmatched tunnel before renewal reconnect")
    }

    @MainActor
    static func coalescePendingEvents() async throws {
        var events: [String] = []
        let scheduler = NetworkChangeScheduler(debounceNanoseconds: 5_000_000,
            evaluateRules: { events.append("rules") },
            reconnect: { events.append("reconnect") })
        scheduler.schedule(addressChanged: true)
        scheduler.schedule()
        scheduler.schedule(addressChanged: true)
        try await waitUntil("coalesced address changes never drained") { !scheduler.isProcessing }
        expect(events == ["rules", "reconnect", "rules"],
            "coalesced address events must retain the renewal flag and evaluate before and after one reconnect")
        events = []
        scheduler.schedule()
        scheduler.schedule()
        try await waitUntil("ordinary network changes never drained") { !scheduler.isProcessing }
        expect(events == ["rules"], "ordinary network changes must evaluate once without reconnecting")
    }

    @MainActor
    static func cancelAndScheduleWhileDraining() async throws {
        let fixture = NetworkFixture()
        let scheduler = NetworkChangeScheduler(debounceNanoseconds: 0,
            evaluateRules: { await fixture.evaluateRules() },
            reconnect: { await fixture.reconnect() })
        scheduler.schedule(addressChanged: true)
        try await waitUntil("the cancellable reconnect never started") { fixture.reconnecting }
        let evaluationsBeforeCancel = fixture.evaluations
        scheduler.cancel()
        expect(scheduler.isProcessing, "cancel must remain processing until its in-flight callback drains")
        fixture.address = "198.51.100.20"
        scheduler.schedule()
        try await Task.sleep(nanoseconds: 5_000_000)
        expect(fixture.evaluations == evaluationsBeforeCancel,
            "a job scheduled after cancellation must wait for the old callback")
        fixture.gate.release()
        try await waitUntil("the replacement job was lost while the cancelled callback drained") { !scheduler.isProcessing }
        expect(!fixture.active && fixture.evaluations == evaluationsBeforeCancel + 1,
            "the replacement job must evaluate once after cancellation finishes")
        expect(fixture.evaluationsWhileReconnecting == 0 && fixture.maximumConcurrentReconnects == 1,
            "cancellation must never overlap the old and replacement jobs")
    }

    @MainActor
    static func coalesceEventsDuringReconnect() async throws {
        let fixture = NetworkFixture()
        let scheduler = NetworkChangeScheduler(debounceNanoseconds: 0,
            evaluateRules: { await fixture.evaluateRules() },
            reconnect: { await fixture.reconnect() })
        scheduler.schedule(addressChanged: true)
        try await waitUntil("the first reconnect never started") { fixture.reconnects == 1 }
        fixture.address = "192.0.2.20"
        scheduler.schedule(addressChanged: true)
        scheduler.schedule()
        scheduler.schedule(addressChanged: true)
        fixture.gate.release()
        try await waitUntil("renewals queued during reconnect were lost") { fixture.reconnects == 2 }
        fixture.gate.release()
        try await waitUntil("the queued reconnect never drained") { !scheduler.isProcessing }
        expect(fixture.reconnects == 2 && fixture.maximumConcurrentReconnects == 1,
            "a burst during reconnect must queue exactly one later reconnect")
        expect(fixture.evaluationsWhileReconnecting == 0,
            "coalesced notifications must not evaluate rules during reconnect")
    }

    @MainActor
    static func cancelDuringRuleEvaluation() async throws {
        let gate = ReconnectGate()
        var evaluations = 0
        var reconnects = 0
        let scheduler = NetworkChangeScheduler(debounceNanoseconds: 0,
            evaluateRules: {
                evaluations += 1
                if evaluations == 1 { await gate.wait() }
            }, reconnect: { reconnects += 1 })
        scheduler.schedule(addressChanged: true)
        try await waitUntil("rule evaluation never started") { evaluations == 1 }
        scheduler.cancel()
        scheduler.schedule(addressChanged: true)
        expect(scheduler.isProcessing && reconnects == 0,
            "a cancelled rule evaluation must retain task ownership until it drains")
        gate.release()
        try await waitUntil("cancelling rule evaluation lost the replacement renewal") { !scheduler.isProcessing }
        expect(evaluations == 3 && reconnects == 1,
            "only the replacement job may reconnect after cancellation during rule evaluation")
    }

    @MainActor
    static func cancelPendingDebounce() async throws {
        var calls = 0
        let scheduler = NetworkChangeScheduler(debounceNanoseconds: 5_000_000,
            evaluateRules: { calls += 1 }, reconnect: { calls += 1 })
        scheduler.schedule(addressChanged: true)
        scheduler.cancel()
        try await waitUntil("a cancelled debounce did not drain") { !scheduler.isProcessing }
        expect(calls == 0, "cancelling before debounce finishes must discard both pending callbacks")
        scheduler.schedule()
        try await waitUntil("a new job after cancellation did not drain") { !scheduler.isProcessing }
        expect(calls == 1, "cancellation must clear an old pending renewal flag")
    }
}
