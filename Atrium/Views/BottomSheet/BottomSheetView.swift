import SwiftUI

struct BottomSheetView: View {
    let project: Project
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("editorPanelHeight") private var panelHeight: Double = 250
    @AppStorage(ChatFontSize.key) private var chatFontSize = ChatFontSize.default

    private var panel: EditorPanel { project.editor }

    var body: some View {
        VStack(spacing: 0) {
            dragBorder
            content
        }
        .frame(maxHeight: panel.isOpen ? panelHeight : 0, alignment: .top)
        .clipped()
        .allowsHitTesting(panel.isOpen)
        .accessibilityHidden(!panel.isOpen)
        .background(colorScheme == .dark ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.bar))
        .environment(\.editorFontSize, EditorFontSize.matching(chat: chatFontSize))
        .environment(project.editor)
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
                    .cursor(.resizeUpDown)
                    .gesture(resizeGesture)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch panel.content {
        case .file(let url):
            FileEditorPanel(fileURL: url, project: project)
        case .diff(let ref):
            DiffPanel(reference: ref, project: project)
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

    @State private var dragStartHeight: Double?

    @State private var dragStartY: CGFloat?

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if dragStartHeight == nil {
                    dragStartHeight = panelHeight
                    dragStartY = value.startLocation.y
                }
                guard let startHeight = dragStartHeight, let startY = dragStartY else { return }
                let delta = startY - value.location.y
                panelHeight = min(max(100, startHeight + delta), 800)
            }
            .onEnded { _ in
                dragStartHeight = nil
                dragStartY = nil
            }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
