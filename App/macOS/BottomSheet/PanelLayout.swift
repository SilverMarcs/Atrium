import SwiftUI

/// Layout contract for bottom-sheet content.
///
/// Each kind of content (the file editor, a diff, a page) wraps itself in
/// `PanelLayout`, supplying a title and trailing actions of its own. The
/// layout supplies the shared chrome: back and forward, the separator,
/// focus mode and the panel toggle, and dragging the header resizes the sheet.
struct PanelLayout<Title: View, Actions: View, Content: View>: View {
    @Environment(EditorPanel.self) private var panel
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder let title: Title
    @ViewBuilder let actions: Actions
    @ViewBuilder let content: Content

    private var borderColor: Color {
        colorScheme == .dark ? Color(nsColor: .shadowColor) : Color(nsColor: .gridColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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

            actions

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isFocusMode {
                        app.sidebarVisibility = .automatic
                        app.showingInspector = true
                    } else {
                        app.sidebarVisibility = .detailOnly
                        app.showingInspector = false
                    }
                }
            } label: {
                Image(systemName: "rectangle.center.inset.filled")
                    .foregroundStyle(isFocusMode ? .accent : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isFocusMode ? "Show Sidebar & Inspector" : "Hide Sidebar & Inspector")

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
        .modifier(SheetResizing(panel: panel))
    }

    private var isFocusMode: Bool {
        app.sidebarVisibility == .detailOnly && !app.showingInspector
    }
}
