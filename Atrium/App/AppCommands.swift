import AtriumProtocol
import SwiftUI

struct AppCommands: Commands {
    @Bindable var app: AppModel
    let updater: UpdaterManager
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.editorPanel) private var editorPanel
    @FocusedValue(\.isMainWindow) private var isMainWindow
    @AppStorage("showHiddenFiles") var showHiddenFiles = false
    @AppStorage(EditorFontSize.key) private var editorFontSize: Double = EditorFontSize.default
    @AppStorage(ChatFontSize.key) private var chatFontSize = ChatFontSize.default

    /// Whether the focused window is the main Atrium window.
    private var mainWindowActive: Bool { isMainWindow == true }

    var body: some Commands {
        // Replace the default "About Atrium" item with one that opens our
        // custom About window scene.
        CommandGroup(replacing: .appInfo) {
            Button("About Atrium") {
                openWindow(id: "about")
            }
        }

        // Sparkle "Check for Updates…" — placed right after the standard About item in the
        // app menu. Lives outside the `mainWindowActive` gate so it stays available
        // regardless of which window is focused.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }

        if mainWindowActive {
            SidebarCommands()
            
            InspectorCommands()
            
            CommandGroup(after: .newItem) {
                Button("New Chat", systemImage: "square.and.pencil") {
                    app.hosts.openNewChat()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!app.hosts.canStartNewChat)
            }

            CommandGroup(replacing: .toolbar) {
                Button {
                    chatFontSize = min(chatFontSize + ChatFontSize.step, ChatFontSize.max)
                    app.activeTerminal?.increaseFontSize()
                    editorFontSize = min(editorFontSize + 0.5, EditorFontSize.max)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .keyboardShortcut("+", modifiers: .command)

                Button {
                    chatFontSize = max(chatFontSize - ChatFontSize.step, ChatFontSize.min)
                    app.activeTerminal?.decreaseFontSize()
                    editorFontSize = max(editorFontSize - 0.5, EditorFontSize.min)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)

                Button {
                    chatFontSize = ChatFontSize.default
                    app.activeTerminal?.resetFontSize()
                    editorFontSize = EditorFontSize.default
                } label: {
                    Label("Actual Size", systemImage: "1.magnifyingglass")
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        editorPanel?.toggle()
                    }
                } label: {
                    Label("Toggle Bottom Panel", systemImage: "rectangle.bottomhalf.inset.filled")
                }
                .keyboardShortcut("j", modifiers: .command)

                Divider()

                Button {
                    showHiddenFiles.toggle()
                } label: {
                    Label(
                        showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files",
                        systemImage: showHiddenFiles ? "eye.slash" : "eye"
                    )
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }

            CommandMenu("Inspector") {
                Button {
                    app.showingInspector = true
                    app.selectedProject?.selectedTab = .files
                } label: {
                    Label("Files Navigator", systemImage: "folder")
                }
                .keyboardShortcut("1", modifiers: .command)

                Button {
                    app.showingInspector = true
                    app.selectedProject?.selectedTab = .git
                } label: {
                    Label("Git Navigator", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .keyboardShortcut("2", modifiers: .command)

                Button {
                    app.showingInspector = true
                    app.selectedProject?.selectedTab = .search
                } label: {
                    Label("Search Navigator", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("3", modifiers: .command)

                Button {
                    app.showingInspector = true
                    app.selectedProject?.selectedTab = .commands
                } label: {
                    Label("Command Runner", systemImage: "apple.terminal")
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button {
                    guard let project = app.selectedProject, let command = project.defaultCommand else { return }
                    app.showingInspector = true
                    if command.isRunning {
                        app.pendingRunReplacement = (project, command)
                    } else {
                        project.run(command)
                    }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(app.selectedProject?.defaultCommand == nil)

                Button {
                    guard let project = app.selectedProject, let command = project.defaultCommand else { return }
                    project.send(.stop, to: command)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(app.selectedProject?.defaultCommand?.isRunning != true)

                Divider()

                Button {
                    app.showingInspector = true
                    app.selectedProject?.selectedTab = .search
                    app.selectedProject?.search.searchFocusTrigger += 1
                } label: {
                    Label("Find in Files", systemImage: "doc.text.magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button {
                    app.showingInspector = true
                    app.selectedProject?.selectedTab = .files
                    app.selectedProject?.fileTree.searchFocusTrigger += 1
                } label: {
                    Label("Go to File", systemImage: "doc.text.magnifyingglass")
                }
                .keyboardShortcut("p", modifiers: .command)
            }

            CommandGroup(after: .textEditing) {
                Button("Find…") {
                    let item = NSMenuItem()
                    item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find and Replace…") {
                    let item = NSMenuItem()
                    item.tag = Int(NSFindPanelAction.setFindString.rawValue)
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }
        }
    }
}
