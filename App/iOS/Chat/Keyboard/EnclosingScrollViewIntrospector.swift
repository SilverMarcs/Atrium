import SwiftUI

/// Hands over the `UIScrollView` behind the SwiftUI `ScrollView` whose content
/// contains this view.
struct EnclosingScrollViewIntrospector: UIViewRepresentable {
    var introspect: (UIScrollView) -> Void
    var onDetach: (UIScrollView) -> Void

    func makeUIView(context: Context) -> EnclosingScrollViewObserverView {
        let view = EnclosingScrollViewObserverView()
        view.isUserInteractionEnabled = false
        view.introspect = introspect
        view.onDetach = onDetach
        return view
    }

    func updateUIView(_ uiView: EnclosingScrollViewObserverView, context: Context) {
        uiView.introspect = introspect
        uiView.onDetach = onDetach
        uiView.resolveScrollView()
    }

    static func dismantleUIView(_ uiView: EnclosingScrollViewObserverView, coordinator: ()) {
        uiView.detach()
        uiView.introspect = nil
        uiView.onDetach = nil
    }
}
