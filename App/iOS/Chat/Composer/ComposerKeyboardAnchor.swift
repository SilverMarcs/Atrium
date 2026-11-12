import SwiftUI

/// Marks the composer's bounds in UIKit, where `TimelineKeyboardFollower`
/// finds it to move the timeline with it as the keyboard shows and hides.
struct ComposerKeyboardAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> ComposerKeyboardAnchorView {
        let view = ComposerKeyboardAnchorView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: ComposerKeyboardAnchorView, context: Context) {}
}

final class ComposerKeyboardAnchorView: UIView {}
