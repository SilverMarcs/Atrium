import SwiftUI

/// The pane beside a chat: its browser, or one of its project's files or
/// diffs, in the window's last split column so their controls get a part of
/// the toolbar of their own, above them, apart from the chat's. Back and
/// forward move through everything it showed.
///
/// The column collapses while the chat's pane is closed (see
/// `PaneColumnCollapse`), but keeps what it showed so it can open again with it.
struct ChatPaneView: View {
    let item: HostTask?
    @Environment(AppModel.self) private var app
    @AppStorage(ChatFontSize.key) private var chatFontSize = ChatFontSize.default

    private var current: PaneItem? { item.flatMap { app.chatPanes.current(for: $0.id) } }
    private var isOpen: Bool { item.map { app.chatPanes.isOpen(for: $0.id) } ?? false }
    private var project: Project? { item.flatMap(app.project(for:)) }

    var body: some View {
        // Toolbar hangs off a stable container, not the content switch, so
        // its items aren't recreated (NSToolbar remove+add) on every switch.
        VStack(spacing: 0) {
            // Shown once the column has slid open, so it doesn't draw squeezed under the inspector.
            content
                .opacity(app.chatPanes.isColumnMoving ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: app.chatPanes.isColumnMoving)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if let item, isOpen {
                ToolbarItem {
                    ControlGroup {
                        Button("Back", systemImage: "chevron.left") { app.chatPanes.goBack(for: item.id) }
                            .disabled(!app.chatPanes.canGoBack(for: item.id))
                        Button("Forward", systemImage: "chevron.right") { app.chatPanes.goForward(for: item.id) }
                            .disabled(!app.chatPanes.canGoForward(for: item.id))
                    }
                    .controlGroupStyle(.navigation)
                }
                if current == .browser, let browser = app.browser(for: item) {
                    PaneBrowserToolbar(browser: browser)
                } else {
                    // Files and diffs add their own.
                    ToolbarSpacer(.flexible)
                }
            }
        }
        .environment(\.editorFontSize, EditorFontSize.matching(chat: chatFontSize))
        // Websites are laid out for 320 points and up; the toolbar above
        // them needs a little more.
        .navigationSplitViewColumnWidth(min: 400, ideal: 520, max: 1200)
    }

    @ViewBuilder
    private var content: some View {
        switch current {
        case .browser:
            if let item, let browser = app.browser(for: item) {
                PaneBrowserView(browser: browser)
            } else {
                ContentUnavailableView("Browser Closed", systemImage: "globe")
            }
        case .file(let url):
            if let project {
                FileEditorPanel(fileURL: url, project: project)
            }
        case .diff(let reference):
            if let project {
                DiffPanel(reference: reference, project: project)
            }
        case nil:
            Color.clear
        }
    }
}

/// Opens or closes the pane beside a chat that has something to show there.
struct ChatPaneToggle: View {
    let item: HostTask
    @Environment(AppModel.self) private var app

    var body: some View {
        let isOpen = app.chatPanes.isOpen(for: item.id)
        Button(isOpen ? "Hide Pane" : "Show Pane", systemImage: "square.split.2x1") {
            withAnimation { app.chatPanes.toggle(for: item.id) }
        }
        .help(isOpen ? "Hide Pane" : "Show Pane")
    }
}
