import SwiftUI

/// The width the timeline's replies are laid out at, which follows the window
/// only once it settles. Wrapping every reply again at each step of a sidebar,
/// inspector or pane sliding, or of the window being resized, is what makes
/// those stutter; meanwhile the replies keep their width, centered in the
/// timeline, and wrap once at the end.
@MainActor
@Observable
final class SettledTimelineWidth {
    private(set) var width: CGFloat?
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// How long the width has to hold still to count as settled.
    private static let settleDelay: Duration = .milliseconds(150)

    func note(_ available: CGFloat) {
        guard available > 0 else { return }
        pending?.cancel()
        guard let width else {
            width = available
            return
        }
        guard available != width else { return }
        pending = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.settleDelay)) != nil else { return }
            self?.width = available
        }
    }
}

extension View {
    /// Lays the timeline out at its settled width, centered in what's there now.
    func settledTimelineWidth(_ settled: SettledTimelineWidth) -> some View {
        modifier(SettledTimelineFrame(settled: settled))
    }
}

/// Reads the settled width here, so its changes don't update the whole chat.
private struct SettledTimelineFrame: ViewModifier {
    let settled: SettledTimelineWidth

    func body(content: Content) -> some View {
        content
            .frame(width: settled.width)
            .frame(maxWidth: .infinity)
    }
}
