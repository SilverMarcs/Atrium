import SwiftUI

extension ScrollGeometry {
    /// How far above the end still counts as being at it.
    private static let bottomTolerance: CGFloat = 40

    /// The offsets the scroll view can rest at, from its top to its end.
    /// `containerSize` leaves out the content insets, so the end is where the
    /// content's bottom meets the view's above the bottom inset. Content
    /// shorter than the view rests at its top only: on iOS it's aligned to
    /// the bottom by a larger top inset.
    var restingOffsets: ClosedRange<CGFloat> {
        let top = -contentInsets.top
        return top...(top + max(0, contentSize.height - containerSize.height))
    }

    /// How far the end of the content is below what's in view.
    var distanceToEnd: CGFloat {
        restingOffsets.upperBound - contentOffset.y
    }

    /// Whether the scroll view shows the end of its content.
    var isAtBottom: Bool {
        distanceToEnd <= Self.bottomTolerance
    }
}
