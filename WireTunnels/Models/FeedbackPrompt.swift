import Foundation

/// Which GitHub nudge the dashboard shows, if any. One at a time, and never sent anywhere:
/// both only open a URL in the browser, so the app stays free of analytics.
enum FeedbackPrompt: Equatable {
    case poll
    case feedback

    /// The feedback tip waits so it never greets a brand-new install.
    static let feedbackDelay: TimeInterval = 7 * 24 * 3600

    static func next(pollDismissed: Bool, feedbackDismissed: Bool,
                     firstSeen: Date, now: Date = Date()) -> FeedbackPrompt? {
        if !pollDismissed { return .poll }
        if !feedbackDismissed, now.timeIntervalSince(firstSeen) >= feedbackDelay { return .feedback }
        return nil
    }
}

enum FeedbackLinks {
    static let repository = URL(string: "https://github.com/FMDigitech/WireTunnels")!
    /// The Discussions poll about what to build next.
    static let poll = URL(string: "https://github.com/FMDigitech/WireTunnels/discussions/46")!
}
