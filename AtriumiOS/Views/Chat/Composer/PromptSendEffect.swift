import SwiftUI

/// Animate the actual bubble relative to its current layout, never a copied
/// destination rectangle. Only render transforms change on animation frames.
struct PromptSendEffect: ViewModifier {
    @Environment(PromptSendAnimator.self) private var animator

    /// Finds this bubble's flight, if it was just sent.
    let flight: (PromptSendAnimator) -> PromptSendFlight?

    func body(content: Content) -> some View {
        if let flight = flight(animator) {
            let source = flight.sourceFrame
            let startedAt = flight.startedAt
            TimelineView(.animation) { _ in
                let progress = PromptSendFlight.progress(since: startedAt, at: .now)
                content
                    .visualEffect { bubble, geometry in
                        let destination = geometry.frame(in: .global)
                        let remaining = 1 - progress
                        return bubble
                            .scaleEffect(0.9 + 0.1 * progress)
                            .offset(
                                x: (source.midX - destination.midX) * remaining,
                                y: (source.midY - destination.midY) * remaining
                            )
                    }
            }
            .onAppear { animator.start(flight.id) }
        } else {
            content
        }
    }
}
