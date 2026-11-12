import SwiftUI

/// Moves the timeline with the composer as the keyboard shows and hides. See
/// `TimelineKeyboardFollower`.
///
/// Apply it to the scroll view's content, so the introspector sits inside
/// the `UIScrollView` it looks for.
struct FollowComposerOnKeyboard: ViewModifier {
    @State private var follower = TimelineKeyboardFollower()
    let followsLatest: () -> Bool

    func body(content: Content) -> some View {
        content
            .background {
                EnclosingScrollViewIntrospector { scrollView in
                    follower.followsLatest = followsLatest
                    follower.attach(to: scrollView)
                } onDetach: { scrollView in
                    follower.detach(from: scrollView)
                }
                .accessibilityHidden(true)
            }
    }
}

extension View {
    /// Keeps the timeline moving with the composer as the keyboard shows and
    /// hides, while `followsLatest` says it keeps its newest message above
    /// the composer.
    func followsComposerOnKeyboard(followsLatest: @escaping () -> Bool) -> some View {
        modifier(FollowComposerOnKeyboard(followsLatest: followsLatest))
    }
}
