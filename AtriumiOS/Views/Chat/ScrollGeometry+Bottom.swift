import SwiftUI

extension ScrollGeometry {
    /// How far above the end still counts as being at it.
    private static let bottomTolerance: CGFloat = 40

    /// Whether the scroll view shows the end of its content.
    var isAtBottom: Bool {
        let maximumOffset = contentSize.height + contentInsets.bottom - containerSize.height
        return contentOffset.y >= maximumOffset - Self.bottomTolerance
    }
}
