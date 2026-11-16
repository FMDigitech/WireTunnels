import Foundation

@main
struct FeedbackPromptTests {
    static func main() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let day: TimeInterval = 24 * 3600
        func next(poll: Bool, tip: Bool, after days: Double) -> FeedbackPrompt? {
            FeedbackPrompt.next(pollDismissed: poll, feedbackDismissed: tip,
                                firstSeen: start, now: start.addingTimeInterval(days * day))
        }
        precondition(next(poll: false, tip: false, after: 0) == .poll, "The poll shows first")
        precondition(next(poll: false, tip: false, after: 30) == .poll, "The poll wins over the tip while open")
        precondition(next(poll: true, tip: false, after: 6) == nil, "The tip must not greet a new install")
        precondition(next(poll: true, tip: false, after: 7) == .feedback, "The tip appears after a week")
        precondition(next(poll: true, tip: true, after: 30) == nil, "Dismissed prompts stay dismissed")
        print("PASS: feedback prompts show the poll first, the tip only after a week, and never twice")
    }
}
