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
/// pane's items follow the chat's: the pane's buttons, then a blank item as
/// wide as it takes to put them just past the pane's edge. The items after
/// the blank one hold its trailing edge in place, and the chat's own buttons
/// stay above the chat.
private struct SidePane: ViewModifier {
    let item: HostTask
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @AppStorage("sidePaneWidth") private var storedWidth: Double = 480
    /// The pane's width while its divider is dragged, saved when it's let go.
    @State private var dragWidth: CGFloat?
    @State private var dragStartWidth: CGFloat?
    /// The width of the chat and the pane together.
    @State private var availableWidth: CGFloat = 0
    @State private var page = SidePanePage()
    /// Where the pane starts and the chat and pane end, in the window.
    @State private var paneMinX: CGFloat = 0
    @State private var detailMaxX: CGFloat = 0
    /// Where the toolbar laid out the blank item.
    @State private var blankFrame: CGRect?
    /// How far the blank item ends from the pane's trailing edge, with the
    /// inspector shown and hidden. It doesn't depend on the blank item's
    /// width, so learning it settles. Guessed wide until measured, since
    /// items too wide for the toolbar go into its overflow menu.
    @State private var trailingInsets: [Bool: CGFloat] = [true: 20, false: 110]

    private static let minimumWidth: CGFloat = 320
    private static let minimumChatWidth: CGFloat = 360
    /// The pane's two toolbar buttons and the gap after them, as the toolbar
    /// lays them out. Their own frames can't be read from here.
    private static let controlsWidth: CGFloat = 77
    /// Half the gap the fixed spacer leaves between the chat's buttons and
    /// the pane's, so the divider runs down the middle of it.
    private static let controlsInset: CGFloat = 9

    private var media: ChatMedia {
        ChatMedia(host: item.host, taskID: item.task.id, directory: item.task.path)
    }

    func body(content: Content) -> some View {
        let shown = app.sidePanes.content(for: item.id)
        let committedWidth = width(for: storedWidth)
        // While the divider is dragged only the pane resizes, over or away
        // from the chat, which keeps its width until the drag ends: laying
        // out the chat's replies again at every step is what made it lag.
        HStack(spacing: 0) {
            content
            if shown != nil {
                Color.clear
                    .frame(width: committedWidth)
            }
        }
        .overlay(alignment: .trailing) {
            if shown != nil {
                HStack(spacing: 0) {
                    Divider()
                        // Up through the toolbar, between the chat's buttons and the pane's.
                        .ignoresSafeArea(.container, edges: .top)
                        .overlay {
                            Color.clear
                                .frame(width: 8)
                                .contentShape(.rect)
                                .pointerStyle(.columnResize)
                                .gesture(resizeGesture)
                        }
                    SidePanePageView(page: page, media: media)
                        .frame(width: max(0, (dragWidth ?? committedWidth) - 1))
                        .background(.windowBackground)
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { paneMinX = $0 }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { detailMaxX = $0 }
        // Learns from where the toolbar settles: while it's moving things, as
        // the inspector opens or closes, the blank item's frame and the
        // inspector's state can belong to different layouts.
        .task(id: ToolbarLayout(blankFrame: blankFrame, isShowingInspector: app.showingInspector)) {
            guard (try? await Task.sleep(for: .milliseconds(400))) != nil else { return }
            learnTrailingInset()
        }
        .task(id: SidePaneLoad(task: item.id, content: shown)) {
            guard case .page(let block) = shown else { return }
            await page.load(block.page, media: media, openURL: openURL)
        }
        .toolbar {
            if shown != nil {
                // Keeps the pane's buttons out of the chat's glass group, with
                // room for the divider between them.
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Close", systemImage: "xmark") { app.sidePanes.close(for: item.id) }
                    SidePanePageDownloadMenu(page: page)
                }
                ToolbarItem(placement: .primaryAction) {
                    Color.clear
                        .frame(width: blankWidth, height: 1)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { blankFrame = $0 }
                        .accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    /// The blank item's width that puts the pane's buttons just past its edge.
    private var blankWidth: CGFloat {
        let end = detailMaxX - (trailingInsets[app.showingInspector] ?? 0)
        return max(0, (end - Self.controlsWidth - Self.controlsInset - paneMinX).rounded(.down))
    }

    /// Learns where the items after the blank one start, ignoring changes
    /// under a point, which come and go as the toolbar snaps to pixels.
    private func learnTrailingInset() {
        guard detailMaxX > 0, let blankFrame, blankFrame.width > 0 else { return }
        // The toolbar's part over the chat and pane can reach a little past them.
        let inset = (detailMaxX - blankFrame.maxX).rounded()
        guard abs(inset) < 400 else { return }
        if abs(inset - (trailingInsets[app.showingInspector] ?? 0)) >= 1 {
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
                dragWidth = width(for: start - value.translation.width)
            }
            .onEnded { _ in
                if let dragWidth { storedWidth = dragWidth }
                dragWidth = nil
                dragStartWidth = nil
            }
    }
}

/// Where the toolbar put the blank item, with the inspector shown or hidden.
private struct ToolbarLayout: Equatable {
    let blankFrame: CGRect?
    let isShowingInspector: Bool
}

/// What the pane loads: the page it shows, in the chat it's beside.
private struct SidePaneLoad: Equatable {
    let task: TaskRef
    let content: SidePaneContent?
}
