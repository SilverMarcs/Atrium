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

    let place: Place
    /// The offset and the top it's measured against. SwiftUI can move both
    /// while the timeline stays outside, which is checked again each time.
    private let offset: CGFloat
    private let top: CGFloat

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
        self.top = place == .within ? 0 : top
    }
}
