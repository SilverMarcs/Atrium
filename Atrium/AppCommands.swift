import SwiftUI

struct AppCommands: Commands {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.editorPanel) private var editorPanel
    @FocusedValue(\.isMainWindow) private var isMainWindow
    @AppStorage("showHiddenFiles") var showHiddenFiles = false
    @AppStorage("defaultChatMode") private var defaultChatMode: AgentProvider = .claude
    @AppStorage("defaultPermissionMode") private var defaultPermissionMode: PermissionMode = .bypassPermissions

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

        if mainWindowActive {
            SidebarCommands()
            
            InspectorCommands()
            
            CommandGroup(after: .newItem) {
                Button {
                    guard let workspace = appState.selectedChat?.workspace else { return }
                    let chat = workspace.addChat(provider: defaultChatMode, permissionMode: defaultPermissionMode)
                    appState.expandedWorkspaceIDs.insert("w:\(workspace.id.uuidString)")
                    appState.selectedChat = chat
                } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appState.selectedChat?.workspace == nil)

                Menu {
                    ForEach(AgentProvider.allCases, id: \.self) { provider in
                        Button {
                            guard let workspace = appState.selectedChat?.workspace else { return }
                            let chat = workspace.addChat(provider: provider, permissionMode: defaultPermissionMode)
                            appState.expandedWorkspaceIDs.insert("w:\(workspace.id.uuidString)")
                            appState.selectedChat = chat
                        } label: {
                            Label(provider.rawValue, image: provider.imageName)
                        }
                    }
                } label: {
                    Label("New Chat With…", systemImage: "plus.bubble")
                }
                .disabled(appState.selectedChat?.workspace == nil)
            }

            CommandGroup(replacing: .toolbar) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        editorPanel?.toggle()
                    }
                } label: {
                    Label("Toggle Editor Panel", systemImage: "rectangle.bottomhalf.inset.filled")
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

                Button {
                    appState.showArchivedWorkspaces.toggle()
                } label: {
                    Label(
                        appState.showArchivedWorkspaces ? "Hide Archived Workspaces" : "Show Archived Workspaces",
                        systemImage: appState.showArchivedWorkspaces ? "tray.and.arrow.up" : "archivebox"
                    )
                }
            }

            CommandMenu("Inspector") {
                Button {
                    appState.showingInspector = true
                    appState.selectedChat?.workspace?.inspectorState.selectedTab = .files
                } label: {
                    Label("Files Navigator", systemImage: "folder")
                }
                .keyboardShortcut("1", modifiers: .command)

                Button {
                    appState.showingInspector = true
                    appState.selectedChat?.workspace?.inspectorState.selectedTab = .git
                } label: {
                    Label("Git Navigator", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .keyboardShortcut("2", modifiers: .command)

                Button {
                    appState.showingInspector = true
                    appState.selectedChat?.workspace?.inspectorState.selectedTab = .search
                } label: {
                    Label("Search Navigator", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("3", modifiers: .command)

                Button {
                    // appState.showingInspector = true
                    appState.selectedChat?.workspace?.inspectorState.selectedTab = .commands
                } label: {
                    Label("Command Runner", systemImage: "apple.terminal")
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button {
                    guard let workspace = appState.selectedChat?.workspace,
                          let command = workspace.defaultCommand else { return }
                    appState.showingInspector = true
                    if command.hasChildProcess {
                        appState.pendingRunReplacement = command
                    } else {
                        workspace.runCommand(command)
                    }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.selectedChat?.workspace?.defaultCommand == nil)

                Button {
                    guard let command = appState.selectedChat?.workspace?.defaultCommand else { return }
                    command.interrupt()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(appState.selectedChat?.workspace?.defaultCommand?.hasChildProcess != true)

                Divider()

                Button {
                    appState.showingInspector = true
                    appState.selectedChat?.workspace?.inspectorState.selectedTab = .search
                    appState.selectedChat?.workspace?.inspectorState.search.searchFocusTrigger += 1
                } label: {
                    Label("Find in Files", systemImage: "doc.text.magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button {
                    appState.showingInspector = true
                    appState.selectedChat?.workspace?.inspectorState.selectedTab = .files
                    appState.selectedChat?.workspace?.inspectorState.fileTree.searchFocusTrigger += 1
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
