import SwiftUI

/// Coordinates "stick to bottom" behavior for a chat-style scroll view.
///
/// The view installs `bottomScrollAnchor(_:proxy:)` on its List/ScrollView,
/// which observes geometry changes. Whenever content grows (streaming text,
/// new blocks) or the viewport shrinks (bottom sheet expands, input grows,
/// plan toggles, attachments appear), and the user *was* near the bottom,
/// we re-pin to the bottom. If the user has scrolled up, we leave them alone.
///
/// External callers (e.g. on chat switch) can also call `scrollToBottom()`
/// directly for an unconditional jump.
@Observable
final class ScrollAnchor {
    /// Whether the scroll view is currently pinned to the bottom (within a
    /// tight tolerance). Updated by the geometry tracker.
    var isAtBottom: Bool = true

    /// While false, the auto-stick logic is suppressed. Used during the
    /// initial layout pass so the chat doesn't fight its own first scroll.
    var isEnabled: Bool = true

    /// Registered by the view modifier; takes `animated`.
    private var scrollAction: ((Bool) -> Void)?

    func register(_ action: @escaping (Bool) -> Void) {
        scrollAction = action
    }

    /// Scroll only if we appear to already be anchored at the bottom.
    func stickIfNeeded(animated: Bool = true) {
        guard isEnabled, isAtBottom else { return }
        scrollAction?(animated)
    }

    /// Unconditional scroll — use for explicit jumps (initial load, send).
    func scrollToBottom(animated: Bool = true) {
        scrollAction?(animated)
    }
}

private struct ScrollAnchorEnvironmentKey: EnvironmentKey {
    static let defaultValue: ScrollAnchor? = nil
}

extension EnvironmentValues {
    var scrollAnchor: ScrollAnchor? {
        get { self[ScrollAnchorEnvironmentKey.self] }
        set { self[ScrollAnchorEnvironmentKey.self] = newValue }
    }
}

private struct ScrollGeometrySnapshot: Equatable {
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
    var offset: CGFloat
}

extension View {
    /// Installs auto-stick-to-bottom behavior. The caller supplies the
    /// `ScrollViewProxy` (so this modifier doesn't need to wrap in its own
    /// reader) and an anchor id that lives somewhere inside the scroll view.
    func bottomScrollAnchor(
        _ anchor: ScrollAnchor,
        proxy: ScrollViewProxy,
        id: AnyHashable = "bottom"
    ) -> some View {
        modifier(BottomScrollAnchorModifier(anchor: anchor, proxy: proxy, anchorID: id))
    }
}

private struct BottomScrollAnchorModifier: ViewModifier {
    let anchor: ScrollAnchor
    let proxy: ScrollViewProxy
    let anchorID: AnyHashable

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollGeometrySnapshot.self) { geometry in
                ScrollGeometrySnapshot(
                    contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height,
                    offset: geometry.contentOffset.y
                )
            } action: { old, new in
                let oldMaxOffset = max(0, old.contentHeight - old.viewportHeight)
                let newMaxOffset = max(0, new.contentHeight - new.viewportHeight)
                let wasNearBottom = old.offset >= oldMaxOffset - 80
                let isPinned = new.offset >= newMaxOffset - 2
                anchor.isAtBottom = isPinned

                guard anchor.isEnabled else { return }
                let contentGrew = new.contentHeight > old.contentHeight + 0.5
                let viewportShrank = new.viewportHeight < old.viewportHeight - 0.5
                if (contentGrew || viewportShrank) && wasNearBottom && !isPinned {
                    let id = anchorID
                    Task { @MainActor in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
            .onAppear {
                let id = anchorID
                anchor.register { animated in
                    if animated {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    } else {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
    }
}
