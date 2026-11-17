import AtriumClient
import AtriumProtocol
import SwiftUI

extension View {
    /// Shows what a chat has open beside it, behind a divider that resizes it.
    func sidePane(for item: HostTask) -> some View {
        modifier(SidePane(item: item))
    }
}

/// The pane keeps its width across chats and launches, and leaves the chat
/// room to read. It's laid out here rather than as a second inspector, which
/// fights the window's inspector for space when both are open.
///
/// The window's toolbar has no section of its own above the pane, so the
/// pane's controls go in one toolbar item after the chat's, as wide as it
/// takes to start at the pane's edge. That keeps the chat's own buttons above
/// the chat.
private struct SidePane: ViewModifier {
    let item: HostTask
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @AppStorage("sidePaneWidth") private var storedWidth: Double = 480
    @State private var dragStartWidth: Double?
    /// The width of the chat and the pane together.
    @State private var availableWidth: CGFloat = 0
    @State private var page = SidePanePage()
    /// Where the pane starts and the chat and pane end, in the window.
    @State private var paneMinX: CGFloat = 0
    @State private var detailMaxX: CGFloat = 0
    /// How far the toolbar items after the pane's controls reach in from the
    /// pane's trailing edge, with the inspector shown and hidden. Measured,
    /// and guessed wide until then, since an item too wide for the toolbar
    /// goes into its overflow menu.
    @State private var trailingInsets: [Bool: CGFloat] = [true: 40, false: 140]

    private static let minimumWidth: CGFloat = 320
    private static let minimumChatWidth: CGFloat = 360

    private var media: ChatMedia {
        ChatMedia(host: item.host, taskID: item.task.id, directory: item.task.path)
    }

    func body(content: Content) -> some View {
        let shown = app.sidePanes.content(for: item.id)
        HStack(spacing: 0) {
            content
            if shown != nil {
                Divider()
                    .overlay {
                        Color.clear
                            .frame(width: 8)
                            .contentShape(.rect)
                            .pointerStyle(.columnResize)
                            .gesture(resizeGesture)
                    }
                    .zIndex(1)
                SidePanePageView(page: page, media: media)
                    .frame(width: width(for: storedWidth))
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { paneMinX = $0 }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { detailMaxX = $0 }
        .task(id: SidePaneLoad(task: item.id, content: shown)) {
            guard case .page(let block) = shown else { return }
            await page.load(block.page, media: media, openURL: openURL)
        }
        .toolbar {
            if shown != nil {
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        SidePanePageControls(page: page) { app.sidePanes.close(for: item.id) }
                            .padding(.leading)
                        Spacer(minLength: 0)
                    }
                    .frame(width: controlsWidth)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { noteControlsEnd($0) }
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    /// The controls' item reaches from the pane's edge to the items after it.
    private var controlsWidth: CGFloat {
        let end = detailMaxX - (trailingInsets[app.showingInspector] ?? 0)
        return max(SidePanePageControls.minimumWidth, end - paneMinX)
    }

    /// Learns where the items after the controls start, from where the
    /// controls' item ends.
    private func noteControlsEnd(_ maxX: CGFloat) {
        guard detailMaxX > 0, maxX > 0, maxX <= detailMaxX else { return }
        let inset = detailMaxX - maxX
        if abs(inset - (trailingInsets[app.showingInspector] ?? 0)) > 0.5 {
            trailingInsets[app.showingInspector] = inset
        }
    }

    /// The width asked for, within what the window leaves beside the chat.
    private func width(for requested: Double) -> CGFloat {
        let maximum = max(Self.minimumWidth, availableWidth - Self.minimumChatWidth)
        return min(max(requested, Self.minimumWidth), maximum)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartWidth ?? width(for: storedWidth)
                dragStartWidth = start
                storedWidth = width(for: start - value.translation.width)
            }
            .onEnded { _ in dragStartWidth = nil }
    }
}

/// What the pane loads: the page it shows, in the chat it's beside.
private struct SidePaneLoad: Equatable {
    let task: TaskRef
    let content: SidePaneContent?
}
