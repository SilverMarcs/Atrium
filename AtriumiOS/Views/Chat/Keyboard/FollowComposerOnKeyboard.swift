import SwiftUI

/// Moves the timeline with the composer as the keyboard shows and hides. See
/// `TimelineKeyboardFollower`.
///
/// Apply it to the scroll view's content, so the introspector sits inside
/// the `UIScrollView` it looks for. Only the iPhone's bottom-bar composer
/// rides the keyboard, so elsewhere this does nothing.
struct FollowComposerOnKeyboard: ViewModifier {
    @State private var follower = TimelineKeyboardFollower()

    func body(content: Content) -> some View {
        content
            .background {
                if UIDevice.current.userInterfaceIdiom == .phone {
                    EnclosingScrollViewIntrospector { scrollView in
                        follower.attach(to: scrollView)
                    } onDetach: { scrollView in
                        follower.detach(from: scrollView)
                    }
                    .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    /// Keeps the timeline moving with the composer as the keyboard shows and
    /// hides.
    func followsComposerOnKeyboard() -> some View {
        modifier(FollowComposerOnKeyboard())
    }
}
