import Foundation

@main
struct TunnelConnectionFeedbackTests {
    static func main() {
        let first = UUID()
        let second = UUID()
        var feedback = TunnelConnectionFeedback()

        let normalIcon = TunnelConnectionStatus.connected.menuBarImage(hasWarnings: false, hasError: false)
        let busyIcon = TunnelConnectionStatus.reconnecting.menuBarImage(hasWarnings: false, hasError: false)
        let lostIcon = TunnelConnectionStatus.connectionLost.menuBarImage(hasWarnings: false, hasError: false)
        let warningIcon = TunnelConnectionStatus.connected.menuBarImage(hasWarnings: true, hasError: false)
        let errorIcon = TunnelConnectionStatus.connected.menuBarImage(hasWarnings: false, hasError: true)
        guard lostIcon == "exclamationmark.circle", errorIcon == "exclamationmark.octagon",
              Set([lostIcon, warningIcon, errorIcon]).count == 3 else {
            fatalError("Loss and error icons must use separate outlined shapes with a clear exclamation mark")
        }
        guard Set([normalIcon, busyIcon, lostIcon]).count == 3,
              warningIcon != normalIcon, errorIcon != normalIcon,
              TunnelConnectionStatus.reconnecting.menuBarImage(hasWarnings: true, hasError: false) == busyIcon else {
            fatalError("Monochrome icons must distinguish activity, loss, warnings, and normal connections")
        }

        feedback.begin(first, reconnecting: false)
        guard feedback.status(for: first) == .connecting else {
            fatalError("Starting a tunnel must show connection activity")
        }
        let automaticAlert = feedback.failed(first, message: "Synthetic timeout", automatic: true)
        feedback.finish(first)
        guard automaticAlert == nil, feedback.status(for: first) == .connectionLost else {
            fatalError("An automatic failure must show a passive warning without an alert")
        }

        feedback.begin(first, reconnecting: true)
        guard feedback.status(for: first) == .reconnecting else {
            fatalError("A retry must show activity instead of the previous failure")
        }
        feedback.connected(first)
        feedback.finish(first)
        guard feedback.status(for: first) == nil else {
            fatalError("Successful recovery must clear the failure indicator")
        }

        feedback.begin(first, reconnecting: true)
        feedback.completeConnection(first, isActive: false)
        feedback.finish(first)
        guard feedback.status(for: first) == .connectionLost else {
            fatalError("A successful command without a confirmed interface must retain a passive warning")
        }
        feedback.begin(first, reconnecting: true)
        feedback.completeConnection(first, isActive: true)
        feedback.finish(first)
        guard feedback.status(for: first) == nil else {
            fatalError("A confirmed interface must clear the recovery warning")
        }

        let manualAlert = feedback.failed(first, message: "Manual failure", automatic: false)
        guard manualAlert == "Manual failure" else {
            fatalError("A user-initiated failure must still produce an actionable alert")
        }
        feedback.lost(second)
        feedback.disconnected(first)
        guard feedback.status(for: first) == nil, feedback.status(for: second) == .connectionLost else {
            fatalError("An intentional disconnect must clear only that tunnel's failure")
        }

        feedback.begin(first, reconnecting: false)
        guard feedback.menuBarStatus(hasActiveTunnels: true) == .connecting else {
            fatalError("Connection activity must be visible even with another active tunnel")
        }
        feedback.finish(first)
        guard feedback.menuBarStatus(hasActiveTunnels: true) == .connectionLost else {
            fatalError("An unrelated active tunnel must not conceal a lost connection")
        }
        feedback.connected(second)
        guard feedback.menuBarStatus(hasActiveTunnels: true) == .connected,
              feedback.menuBarStatus(hasActiveTunnels: false) == .idle else {
            fatalError("Recovered connections must restore the normal menu bar state")
        }

        feedback.lost(second)
        feedback.retain(tunnelIDs: [first])
        guard feedback.menuBarStatus(hasActiveTunnels: false) == .idle else {
            fatalError("Deleting a tunnel must remove its stale warning")
        }
        print("PASS: automatic failures stay passive and connection indicators follow recovery")
    }
}
