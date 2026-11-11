import SwiftUI

/// Stops the timeline clipping its content while a sent prompt flies in from
/// the composer, which starts outside the timeline's bounds.
struct SendFlightScrollClip: ViewModifier {
    @Environment(PromptSendAnimator.self) private var animator

    func body(content: Content) -> some View {
        content
            .scrollClipDisabled(!animator.flights.isEmpty)
    }
}

extension View {
    /// Lets a bubble flying in from the composer draw outside the timeline
    /// while it travels. Only this modifier observes flights, so they never
    /// re-render the timeline's rows.
    func showsSendFlightsUnclipped() -> some View {
        modifier(SendFlightScrollClip())
    }
}
