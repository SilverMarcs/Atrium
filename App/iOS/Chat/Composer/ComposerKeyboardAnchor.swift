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

final class ComposerKeyboardAnchorView: UIView {
    /// Called in the Core Animation commit's display phase once asked for
    /// with `setNeedsCommitCallback()`: after SwiftUI has laid out and
    /// animated the composer for the frame being committed.
    var onCommit: (() -> Void)? {
        get { hook.onDisplay }
        set { hook.onDisplay = newValue }
    }

    private let hook = DisplayHook()
    private let hookLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        hookLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        hookLayer.opacity = 0
        hookLayer.delegate = hook
        layer.addSublayer(hookLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setNeedsCommitCallback() {
        hookLayer.setNeedsDisplay()
    }

    /// Runs `onDisplay` instead of drawing.
    private final class DisplayHook: NSObject, CALayerDelegate {
        var onDisplay: (() -> Void)?

        func display(_ layer: CALayer) {
            MainActor.assumeIsolated { onDisplay?() }
        }

        func action(for layer: CALayer, forKey event: String) -> (any CAAction)? {
            NSNull()
        }
    }
}
