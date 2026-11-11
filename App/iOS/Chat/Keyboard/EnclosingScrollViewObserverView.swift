import UIKit

/// Resolves the scroll view when UIKit actually attaches and lays out this view.
/// SwiftUI can create the representable before it has any scroll-view ancestor.
final class EnclosingScrollViewObserverView: UIView {
    var introspect: ((UIScrollView) -> Void)?
    var onDetach: ((UIScrollView) -> Void)?
    private weak var resolvedScrollView: UIScrollView?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        resolveScrollView()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveScrollView()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        resolveScrollView()
    }

    func resolveScrollView() {
        guard window != nil else {
            detach()
            return
        }
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView {
                if resolvedScrollView !== scrollView {
                    detach()
                    resolvedScrollView = scrollView
                }
                introspect?(scrollView)
                return
            }
            candidate = view.superview
        }
        detach()
    }

    func detach() {
        guard let scrollView = resolvedScrollView else { return }
        resolvedScrollView = nil
        onDetach?(scrollView)
    }
}
