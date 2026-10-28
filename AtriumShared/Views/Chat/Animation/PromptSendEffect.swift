import SwiftUI

/// Animate the actual bubble relative to its current layout, never a copied
/// destination rectangle. Only render transforms change on animation frames.
/// The view structure is the same with or without a flight, so landing never
/// rebuilds the bubble.
struct PromptSendEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PromptSendAnimator.self) private var animator

    /// Finds this bubble's flight, if it was just sent.
    let flight: (PromptSendAnimator) -> PromptSendFlight?

    func body(content: Content) -> some View {
        let flight = reduceMotion ? nil : flight(animator)
        let source = flight?.sourceFrame
        let startedAt = flight?.startedAt
        TimelineView(.animation(paused: flight == nil)) { context in
            let progress = source == nil ? 1 : PromptSendFlight.progress(since: startedAt, at: context.date)
            content
                .visualEffect { bubble, geometry in
                    let destination = geometry.frame(in: .global)
                    let remaining = 1 - progress
                    let offset = source.map {
                        CGSize(
                            width: ($0.midX - destination.midX) * remaining,
                            height: ($0.midY - destination.midY) * remaining
                        )
                    } ?? .zero
                    return bubble
                        .scaleEffect(0.9 + 0.1 * progress)
                        .offset(offset)
                }
        }
        .onChange(of: flight?.id, initial: true) { _, id in
            if let id { animator.start(id) }
        }
    }
}
