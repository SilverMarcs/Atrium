import SwiftUI

/// Finds only the native editor beside this anchor in the inline composer.
struct ComposerPasteAnchor: UIViewRepresentable {
    let composer: TaskComposer

    func makeUIView(context: Context) -> SearchIntrospectionView {
        let view = SearchIntrospectionView()
        configure(view)
        return view
    }

    func updateUIView(_ view: SearchIntrospectionView, context: Context) {
        configure(view)
    }

    private func configure(_ view: SearchIntrospectionView) {
        view.onAttach = { [weak view] in
            if let view { install(from: view) }
        }
        Task { @MainActor [weak view] in
            await Task.yield()
            if let view { install(from: view) }
        }
    }

    private func install(from anchor: UIView) {
        var parent = anchor.superview
        while let view = parent, !(view is UIWindow) {
            if install(in: view, beside: anchor) { return }
            parent = view.superview
        }
    }

    private func install(in view: UIView, beside anchor: UIView) -> Bool {
        // Stay with the editor this background belongs to, even when the
        // task screen also contains a search field or another text input.
        if view is UITextField || view is UITextView {
            guard view.convert(view.bounds, to: anchor).intersects(anchor.bounds) else { return false }
        }
        if let field = view as? UITextField {
            composer.pasteDelegate.configure(field)
            return true
        }
        if let field = view as? UITextView {
            composer.pasteDelegate.configure(field)
            return true
        }
        return view.subviews.contains { install(in: $0, beside: anchor) }
    }
}
