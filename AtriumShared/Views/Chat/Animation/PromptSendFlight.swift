import SwiftUI

/// One bubble's flight. A shared clock survives the pending row being
/// replaced by the transcript's message.
@MainActor
@Observable
final class PromptSendFlight: Identifiable {
    let id: PendingPrompt.ID
    let sourceFrame: CGRect
    var startedAt: ContinuousClock.Instant?
    var confirmedMessageID: TranscriptMessage.ID?

    init(promptID: PendingPrompt.ID, sourceFrame: CGRect) {
        id = promptID
        self.sourceFrame = sourceFrame
    }

    nonisolated static let duration: TimeInterval = 0.55
    nonisolated private static let spring = Spring(response: duration * 0.25 / 0.38, dampingRatio: 0.8)

    nonisolated static func progress(since start: ContinuousClock.Instant?, at now: ContinuousClock.Instant) -> CGFloat {
        guard let start else { return 0 }
        let seconds = start.duration(to: now) / .seconds(1)
        guard seconds < duration else { return 1 }
        return spring.value(target: CGFloat(1), time: max(0, seconds))
    }
}
