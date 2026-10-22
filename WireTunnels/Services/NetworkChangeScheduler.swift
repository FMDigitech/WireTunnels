import Foundation

/// Coalesces network notifications while keeping rule evaluation and physical
/// interface reconnects in one sequence, including when callbacks suspend.
@MainActor
final class NetworkChangeScheduler {
    private let debounceNanoseconds: UInt64
    private let evaluateRules: @MainActor () async -> Void
    private let reconnect: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var rulesPending = false
    private var addressChangePending = false
    private var lastEventUptime: UInt64 = 0

    var isProcessing: Bool { task != nil }

    init(
        debounceNanoseconds: UInt64 = 500_000_000,
        evaluateRules: @escaping @MainActor () async -> Void,
        reconnect: @escaping @MainActor () async -> Void
    ) {
        self.debounceNanoseconds = debounceNanoseconds
        self.evaluateRules = evaluateRules
        self.reconnect = reconnect
    }

    func schedule(addressChanged: Bool = false) {
        rulesPending = true
        addressChangePending = addressChangePending || addressChanged
        lastEventUptime = DispatchTime.now().uptimeNanoseconds
        if task == nil { startProcessing() }
    }

    func cancel() {
        rulesPending = false
        addressChangePending = false
        task?.cancel()
        // A callback may ignore cancellation until its external operation ends.
        // Keep ownership of the task until it actually finishes draining.
    }

    private func startProcessing() {
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.processPendingChanges()
            self.task = nil
            // An event arriving after cancel must wait for the old callback, but
            // must not inherit that task's cancelled state or disappear with it.
            if self.rulesPending { self.startProcessing() }
        }
    }

    private func processPendingChanges() async {
        while !Task.isCancelled && rulesPending {
            // Read the latest notification time again after each suspension so
            // bursts settle for a full debounce interval before acting.
            while !Task.isCancelled {
                let elapsed = DispatchTime.now().uptimeNanoseconds - lastEventUptime
                guard elapsed < debounceNanoseconds else { break }
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds - elapsed)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let shouldReconnect = addressChangePending
            rulesPending = false
            addressChangePending = false

            await evaluateRules()
            guard !Task.isCancelled else { return }
            if shouldReconnect {
                await reconnect()
                guard !Task.isCancelled else { return }
                // Addresses may change while reconnect is awaiting the helper.
                await evaluateRules()
            }
        }
    }
}
