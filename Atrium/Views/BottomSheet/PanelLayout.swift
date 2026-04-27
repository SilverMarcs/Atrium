import SwiftUI

/// Preference key that lets the bottom sheet measure the panel header height.
struct PanelHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Layout contract for bottom-sheet panel content.
///
/// Each panel type (file editor, diff viewer, etc.) wraps its content in
/// `PanelLayout`, supplying a title and trailing actions specific to that
/// content type. The layout is responsible for the shared chrome: navigation
/// buttons, the separator, and the trailing toggle button.
struct PanelLayout<Title: View, Actions: View, Content: View>: View {
    @Environment(EditorPanel.self) private var panel
    // @Environment(\.openWindow) private var openWindow
    @Environment(\.isDetachedEditor) private var isDetached
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("editorPanelHeight") private var panelHeight: Double = 250

    @ViewBuilder let title: Title
    @ViewBuilder let actions: Actions
    @ViewBuilder let content: Content

    private var borderColor: Color {
        colorScheme == .dark ? Color(nsColor: .shadowColor) : Color(nsColor: .gridColor)
    }

    var body: some View {
        if isDetached {
            content
        } else {
            VStack(spacing: 0) {
                header
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: PanelHeaderHeightKey.self, value: geo.size.height)
                        }
                    )
                Rectangle()
                    .fill(borderColor)
                    .frame(height: 1)
                content
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            if panel.content != nil {
                Button { panel.goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(!panel.canGoBack)
                .help("Back")

                Button { panel.goForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(!panel.canGoForward)
                .help("Forward")

                Divider()
                    .frame(height: 15)
            }

            title

            Spacer()

            actions

            // MARK: Open in New Window (disabled for now)
            // if let content = panel.content {
            //     Button {
            //         openWindow(value: content)
            //     } label: {
            //         Image(systemName: "arrow.up.forward.square")
            //     }
            //     .buttonStyle(.borderless)
            //     .help("Open in New Window")
            // }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    panel.toggle()
                }
            } label: {
                Image(systemName: "inset.filled.bottomthird.square")
                    .foregroundStyle(panel.isOpen ? .accent : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Toggle Panel")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.background.secondary)
        .cursor(.resizeUpDown)
        .gesture(resizeGesture)
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
