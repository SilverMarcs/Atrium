import SwiftUI

/// The sheet under a chat: a file, a diff or a page an agent showed, with
/// back and forward through them.
struct BottomSheetView: View {
    let panel: EditorPanel
    let project: Project?
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SheetResizing.heightKey) private var height = SheetResizing.defaultHeight
    @AppStorage(ChatFontSize.key) private var chatFontSize = ChatFontSize.default

    var body: some View {
        VStack(spacing: 0) {
            dragBorder
            content
        }
        .frame(maxHeight: panel.isOpen ? height : 0, alignment: .top)
        .clipped()
        .allowsHitTesting(panel.isOpen)
        .accessibilityHidden(!panel.isOpen)
        .background(colorScheme == .dark ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.bar))
        .environment(\.editorFontSize, EditorFontSize.matching(chat: chatFontSize))
        .environment(panel)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color(nsColor: .shadowColor) : Color(nsColor: .gridColor)
    }

    private var dragBorder: some View {
        Rectangle()
            .fill(borderColor)
            .frame(height: 1)
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .modifier(SheetResizing(panel: panel))
            }
    }

    @ViewBuilder
    private var content: some View {
        switch panel.content {
        case .file(let url):
            if let project { FileEditorPanel(fileURL: url, project: project) }
        case .diff(let ref):
            if let project { DiffPanel(reference: ref, project: project) }
        case .page(let block, let task):
            // A page from another of the project's chats keeps that chat's pages and versions.
            if let item = app.hosts.task(task) {
                PageSheetPanel(item: item, shown: block)
            } else {
                PanelLayout {} actions: {} content: {
                    ContentUnavailableView("Page Unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text("The chat that showed it is gone."))
                }
            }
        case .none:
            PanelLayout {
                // no title
            } actions: {
                // no actions
            } content: {
                // no content
            }
        }
    }
}

/// Drags the sheet taller or shorter; dragging it nearly shut closes it.
struct SheetResizing: ViewModifier {
    static let heightKey = "editorPanelHeight"
    static let defaultHeight: Double = 250

    let panel: EditorPanel
    @AppStorage(Self.heightKey) private var height = Self.defaultHeight
    @State private var dragStartHeight: Double?

    func body(content: Content) -> some View {
        content
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? height
                        dragStartHeight = start
                        let target = start + value.startLocation.y - value.location.y
                        if target < 40 {
                            withAnimation(.easeInOut(duration: 0.2)) { panel.collapse() }
                        } else {
                            height = min(max(100, target), 800)
                        }
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
    }
}
