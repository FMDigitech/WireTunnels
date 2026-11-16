import SwiftUI

/// Dismissible card at the top of the dashboard that points to GitHub: first the roadmap poll,
/// later a feedback/star tip. Dismissal is remembered locally; nothing is sent from the app.
struct FeedbackBanner: View {
    @AppStorage("feedbackFirstSeen") private var firstSeen = 0.0
    @AppStorage("feedbackPollDismissed") private var pollDismissed = false
    @AppStorage("feedbackTipDismissed") private var tipDismissed = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let prompt = FeedbackPrompt.next(
                pollDismissed: pollDismissed,
                feedbackDismissed: tipDismissed,
                firstSeen: firstSeen == 0 ? Date() : Date(timeIntervalSince1970: firstSeen)
            ) {
                card(for: prompt)
            }
        }
        .onAppear {
            if firstSeen == 0 { firstSeen = Date().timeIntervalSince1970 }
        }
    }

    private func card(for prompt: FeedbackPrompt) -> some View {
        let isPoll = prompt == .poll
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: isPoll ? "checklist" : "heart.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isPoll ? "What should WireTunnels do next?" : "Enjoying WireTunnels?")
                        .font(.headline)
                    Text(isPoll
                         ? "Vote in a one-minute poll on GitHub. The app sends nothing; the button only opens the page."
                         : "Leave feedback or a star on GitHub. It helps a lot.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isPoll ? "Vote on GitHub" : "Open GitHub") {
                    openURL(isPoll ? FeedbackLinks.poll : FeedbackLinks.repository)
                    dismiss(prompt)
                }
                .buttonStyle(.borderedProminent)
                Button(isPoll ? "Not now" : "Dismiss") { dismiss(prompt) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            Divider()
        }
    }

    private func dismiss(_ prompt: FeedbackPrompt) {
        if prompt == .poll { pollDismissed = true } else { tipDismissed = true }
    }
}
