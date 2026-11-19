import SwiftUI

/// Where a timeline rests against the offsets it can scroll to, which
/// SwiftUI can leave it outside of: see `TaskChatView`.
struct TimelineRestingRange: Equatable {
    enum Place: Equatable {
        case within
        /// Above its top, the content drawn lower than it can be scrolled to.
        case beforeTop
        /// Past its end or, when it fits in the view, anywhere but there.
        case pastEnd
    }

    /// What the range is measured from. Putting the timeline back again
    /// while none of it changes lands it where it went the last time.
    struct Layout: Equatable {
        var top: CGFloat = 0
        var contentHeight: CGFloat = 0
        var containerHeight: CGFloat = 0
        var bottomInset: CGFloat = 0
    }

    let place: Place
    /// The layout and the offset. SwiftUI can move both while the timeline
    /// stays outside, which is checked again each time.
    let layout: Layout
    private let offset: CGFloat

    /// How far outside counts, beyond rounding.
    private static let tolerance: CGFloat = 2

    init(_ geometry: ScrollGeometry) {
        // A timeline shorter than the view has one offset to rest at.
        let top = geometry.restingOffsets.lowerBound
        let end = geometry.restingOffsets.upperBound
        let offset = geometry.contentOffset.y
        if offset > end + Self.tolerance || (end == top && offset < top - Self.tolerance) {
            place = .pastEnd
        } else if offset < top - Self.tolerance {
            place = .beforeTop
        } else {
            place = .within
        }
        // Moves within the range don't need checking.
        self.offset = place == .within ? 0 : offset
        layout = place == .within ? Layout() : Layout(
            top: top,
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height,
            bottomInset: geometry.contentInsets.bottom
        )
    }

    init() {
        place = .within
        layout = Layout()
        offset = 0
    }
}
