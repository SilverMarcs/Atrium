import SwiftUI

struct AppCommands: Commands {
    @Bindable var app: AppModel
    let updater: UpdaterManager
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.editorPanel) private var editorPanel
    @FocusedValue(\.isMainWindow) private var isMainWindow
    @FocusedValue(\.latestPromptEdit) private var latestPromptEdit
    @FocusedValue(\.showScratchpad) private var showScratchpad
    @AppStorage("showHiddenFiles") var showHiddenFiles = false
    @AppStorage(ChatFontSize.key) private var chatFontSize = ChatFontSize.default

    /// Whether the focused window is the main Atrium window.
    private var mainWindowActive: Bool { isMainWindow == true }

    private var canOpenTerminal: Bool {
        guard let task = app.selectedTask else { return false }
        return task.host.isLocal && task.task.actions.contains(.openTerminal)
    }

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

                // The terminal runs on the task's host, so only this Mac's own chats open in one.
                Button("Open in Terminal", systemImage: "terminal") {
                    guard let task = app.selectedTask else { return }
                    task.host.send(.task(id: task.task.id, action: .openTerminal))
                }
                .disabled(!canOpenTerminal)
            }

            CommandGroup(after: .sidebar) {
                Button {
                    app.sidebarSearchFocusRequest += 1
                } label: {
                    Label("Filter Sidebar", systemImage: "line.3.horizontal.decrease")
                }
                .keyboardShortcut("j", modifiers: [.command, .option])
            }

            CommandGroup(replacing: .toolbar) {
                Button {
                    chatFontSize = min(chatFontSize + ChatFontSize.step, ChatFontSize.max)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .keyboardShortcut("+", modifiers: .command)

                Button {
                    chatFontSize = max(chatFontSize - ChatFontSize.step, ChatFontSize.min)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)

                Button {
                    chatFontSize = ChatFontSize.default
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

                Button {
                    showScratchpad?()
                } label: {
                    Label("Scratchpad", systemImage: "note.text")
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(showScratchpad == nil)

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
                    app.showInspector(.files)
                } label: {
                    Label("Files Navigator", systemImage: "folder")
                }
                .keyboardShortcut("1", modifiers: .command)

                Button {
                    app.showInspector(.git)
                } label: {
                    Label("Git Navigator", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .keyboardShortcut("2", modifiers: .command)

                // The browser takes Search's place, which is hidden for now (InspectorTab.shown).
                Button {
                    app.showInspector(.browser)
                } label: {
                    Label("Browser", systemImage: "globe")
                }
                .keyboardShortcut("3", modifiers: .command)

                Button {
                    app.showInspector(.simulator)
                } label: {
                    Label("Simulator", systemImage: "iphone")
                }
                .keyboardShortcut("4", modifiers: .command)

                Button {
                    app.showInspector(.commands)
                } label: {
                    Label("Command Runner", systemImage: "apple.terminal")
                }
                .keyboardShortcut("5", modifiers: .command)

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
                    app.showInspector(.files)
                    app.selectedProject?.fileTree.searchFocusTrigger += 1
                } label: {
                    Label("Go to File", systemImage: "doc.text.magnifyingglass")
                }
                .keyboardShortcut("p", modifiers: .command)
            }

            CommandGroup(after: .textEditing) {
                Button("Edit Last Message", systemImage: "pencil") {
                    latestPromptEdit?.perform()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(latestPromptEdit == nil)

                Divider()

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
