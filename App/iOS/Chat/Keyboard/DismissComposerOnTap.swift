import SwiftUI

/// Closes the composer as soon as the reader taps the timeline, without
/// keeping the tap from rows and buttons beneath it.
///
/// Apply it to the scroll view's content, so the introspector sits inside
/// the `UIScrollView` it looks for.
struct DismissComposerOnTap: ViewModifier {
    @State private var recognizer = TimelineTapRecognizer()
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .background {
                EnclosingScrollViewIntrospector { scrollView in
                    recognizer.onTap = dismiss
                    recognizer.install(in: scrollView)
                } onDetach: { scrollView in
                    recognizer.remove(from: scrollView)
                }
                .accessibilityHidden(true)
            }
    }
}

/// A tap recognizer that recognizes alongside every other gesture and never
/// cancels or delays touches.
@MainActor
final class TimelineTapRecognizer: NSObject, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?
    private lazy var recognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        return recognizer
    }()

    func install(in scrollView: UIScrollView) {
        guard recognizer.view !== scrollView else { return }
        recognizer.view?.removeGestureRecognizer(recognizer)
        scrollView.addGestureRecognizer(recognizer)
    }

    func remove(from scrollView: UIScrollView) {
        guard recognizer.view === scrollView else { return }
        scrollView.removeGestureRecognizer(recognizer)
    }

    @objc private func tapped() {
        onTap?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = gestureRecognizer.view else { return true }
        return !view.hasComposerKeeper(under: touch)
    }
}

/// Marks content in the timeline that a tap on leaves the composer open.
private struct ComposerKeeper: UIViewRepresentable {
    func makeUIView(context: Context) -> ComposerKeeperView {
        let view = ComposerKeeperView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: ComposerKeeperView, context: Context) {}
}

final class ComposerKeeperView: UIView {}

private extension UIView {
    func hasComposerKeeper(under touch: UITouch) -> Bool {
        subviews.contains { subview in
            if subview is ComposerKeeperView, subview.bounds.contains(touch.location(in: subview)) { return true }
            return subview.hasComposerKeeper(under: touch)
        }
    }
}

extension View {
    /// Closes the composer when the timeline around this content is tapped.
    func dismissesComposerOnTap(_ dismiss: @escaping () -> Void) -> some View {
        modifier(DismissComposerOnTap(dismiss: dismiss))
    }

    /// Leaves the composer open when this content in the timeline is tapped,
    /// as for controls that set up what it sends.
    func keepsComposerOpenOnTap() -> some View {
        background(ComposerKeeper().accessibilityHidden(true))
    }
}
