import SwiftUI

/// The width the timeline's replies wrap at. It follows the window's width as
/// a sidebar, inspector or pane slides or the window is resized, but at most
/// a few times a second rather than on every frame: wrapping every reply
/// again at each step is what makes those stutter. The last width always
/// lands, so the replies end up wrapped at the width the window settles on.
@MainActor
@Observable
final class TimelineWrapWidth {
    private(set) var width: CGFloat?
    @ObservationIgnored private var latest: CGFloat = 0
    @ObservationIgnored private var lastWrap = ContinuousClock.now
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// The least time between two wraps while the width keeps changing.
    private static let interval: Duration = .milliseconds(80)

    func note(_ available: CGFloat) {
        guard available > 0 else { return }
        latest = available
        guard width != nil else {
            wrap()
            return
        }
        // A wrap already on its way takes the newest width.
        guard pending == nil, latest != width else { return }
        let wait = Self.interval - (ContinuousClock.now - lastWrap)
        guard wait > .zero else {
            wrap()
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.pending = nil
            self?.wrap()
        }
    }

    private func wrap() {
        guard latest != width else { return }
        width = latest
        lastWrap = .now
    }
}

extension View {
    /// Lays the timeline out at the width its replies wrap at, centered in
    /// what's there now.
    func timelineWrapWidth(_ wrapWidth: TimelineWrapWidth) -> some View {
        modifier(TimelineWrapFrame(wrapWidth: wrapWidth))
    }
}

/// Reads the wrap width here, so its changes don't update the whole chat.
private struct TimelineWrapFrame: ViewModifier {
    let wrapWidth: TimelineWrapWidth

    func body(content: Content) -> some View {
        content
            .frame(width: wrapWidth.width)
            // The replies' width is no minimum for the chat: otherwise a
            // sidebar opening, which the chat can't shrink for, widens the
            // window past the screen instead.
            .frame(minWidth: 0, maxWidth: .infinity)
    }
}
