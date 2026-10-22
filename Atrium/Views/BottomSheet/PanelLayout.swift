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
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("editorPanelHeight") private var panelHeight: Double = 250

    @ViewBuilder let title: Title
    @ViewBuilder let actions: Actions
    @ViewBuilder let content: Content

    private var borderColor: Color {
        colorScheme == .dark ? Color(nsColor: .shadowColor) : Color(nsColor: .gridColor)
    }

    var body: some View {
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

            if panel.isOpen {
                actions

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isFocusMode {
                            appState.sidebarVisibility = .automatic
                            appState.showingInspector = true
                        } else {
                            appState.sidebarVisibility = .detailOnly
                            appState.showingInspector = false
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.center.inset.filled")
                        .foregroundStyle(isFocusMode ? .accent : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isFocusMode ? "Show Sidebar & Inspector" : "Hide Sidebar & Inspector")
            }

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

    private var isFocusMode: Bool {
        appState.sidebarVisibility == .detailOnly && !appState.showingInspector
    }

    @State private var dragStartHeight: Double?
    @State private var dragStartY: CGFloat?

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if dragStartHeight == nil {
                    // When collapsed, anchor the drag at the minimum expanded height
                    // so any upward motion immediately expands the panel.
                    dragStartHeight = panel.isOpen ? panelHeight : 100
                    dragStartY = value.startLocation.y
                }
                guard let startHeight = dragStartHeight, let startY = dragStartY else { return }
                let delta = startY - value.location.y
                let target = startHeight + delta
                let collapseThreshold: Double = 40
                if target >= 100 {
                    if !panel.isOpen { panel.expand() }
                    panelHeight = min(target, 800)
                } else if target < collapseThreshold {
                    if panel.isOpen { panel.collapse() }
                } else {
                    // Between collapseThreshold and 100: keep panel open, clamped at min.
                    if !panel.isOpen { panel.expand() }
                    panelHeight = 100
                }
            }
            .onEnded { _ in
                dragStartHeight = nil
                dragStartY = nil
            }
    }
}
