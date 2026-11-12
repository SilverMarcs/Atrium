import SwiftUI

/// Holds the new chat's pickers above the composer, scrolling them where they
/// don't all fit, as above the keyboard with larger text or more pickers.
///
/// Laid out at their full height, they pushed the composer down under the
/// keyboard instead.
struct NewChatPickerScroller<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var hidesPickersAbove = false

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // As tall as the pickers where there's room, and only what there is
        // where there isn't.
        .frame(maxHeight: contentHeight)
        // The pickers nearest the composer stay in view.
        .defaultScrollAnchor(.bottom)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 1
        } action: { _, isScrolled in
            hidesPickersAbove = isScrolled
        }
        // Pickers scrolled out of view fade out at the top edge rather than
        // being cut off.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: hidesPickersAbove ? Self.fadeHeight : 0)
                Color.black
            }
        }
    }

    private static var fadeHeight: CGFloat { 24 }
}
