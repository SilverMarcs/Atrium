import SwiftUI

/// Holds the newest prompt sent from this device at the top of the timeline,
/// as chat apps do. The prompt and everything after it form the latest turn,
/// which is at least as tall as the viewport with the keyboard hidden, so
/// there's always room to scroll the prompt to the top; the reply fills the
/// blank space below it as it arrives.
///
/// Sizing the turn for the viewport without the keyboard keeps the prompt
/// still as the keyboard comes and goes: the keyboard only covers or
/// uncovers blank space below the reply.
@MainActor
@Observable
final class TimelineAnchorSpace {
    /// The scroll target at the top of the latest turn.
    static let turnID = "latestTurn"
    /// The timeline's bottom scroll target, which follows the turn.
    static let bottomTargetHeight: CGFloat = 1

    /// The row that starts the latest turn once sent: a pending prompt's
    /// timeline ID, or a transcript message's ID.
    var anchorID: String?
    /// The height the timeline shows its content in with the keyboard
    /// hidden: the tallest it has been at this width, since the keyboard only
    /// ever takes from it.
    private(set) var restingViewportHeight: CGFloat = 0
    /// The latest turn's own height, which only closures read.
    @ObservationIgnored private(set) var turnHeight: CGFloat = 0
    @ObservationIgnored private var viewportWidth: CGFloat = 0
    @ObservationIgnored private var viewportHeight: CGFloat = 0

    /// The latest turn's height when its prompt is at the top of the resting
    /// viewport and the timeline is scrolled to the end.
    var turnMinimumHeight: CGFloat {
        max(0, restingViewportHeight - Self.bottomTargetHeight)
    }

    /// Whether the latest turn still fits below its prompt held at the top,
    /// rather than having grown past the viewport.
    var isHolding: Bool {
        anchorID != nil && turnHeight <= turnMinimumHeight
    }

    func setTurnHeight(_ height: CGFloat) {
        turnHeight = height
    }

    /// Records the size the timeline shows its content in. A new width, such
    /// as on rotation, starts afresh.
    func noteViewport(_ size: CGSize) {
        viewportHeight = size.height
        if size.width != viewportWidth {
            viewportWidth = size.width
            setRestingHeight(size.height)
        } else if size.height > restingViewportHeight {
            setRestingHeight(size.height)
        }
    }

    /// Takes the height with the keyboard gone as the resting height, which
    /// may be shorter than before if the bars have grown.
    func keyboardDidHide() {
        setRestingHeight(viewportHeight)
    }

    /// Lets the timeline end with its content again, as when another task opens.
    func reset() {
        anchorID = nil
        turnHeight = 0
    }

    private func setRestingHeight(_ height: CGFloat) {
        if restingViewportHeight != height { restingViewportHeight = height }
    }
}
