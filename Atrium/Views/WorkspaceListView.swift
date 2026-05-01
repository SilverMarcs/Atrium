import SwiftUI
import AppKit

struct WorkspaceListView: View {
    @Environment(AppState.self) private var appState
    @Environment(WorkspaceStore.self) private var store
    @AppStorage("hideSettingsButton") private var hideSettingsButton = false
    @AppStorage("sidebarRowSize") private var sidebarRowSize: SidebarRowSizePreference = .medium
    @AppStorage("defaultChatMode") private var defaultChatMode: AgentProvider = .claude
    @AppStorage("defaultPermissionMode") private var defaultPermissionMode: PermissionMode = .bypassPermissions

    let searchText: String

    init(searchText: String = "") {
        self.searchText = searchText
    }

    private var visibleWorkspaces: [Workspace] {
        guard !searchText.isEmpty else {
            return store.workspaces.filter { ws in
                appState.showArchivedWorkspaces
                    || !ws.isArchived
                    || ws.hasActiveChildProcess
                    || ws.hasActiveChats
            }
        }
        return store.workspaces.filter { $0.name.localizedStandardContains(searchText) }
    }

    var body: some View {
        @Bindable var appState = appState
        List(selection: $appState.selectedChat) {
            ForEach(visibleWorkspaces) { workspace in
                let workspaceID = "w:\(workspace.id.uuidString)"
                DisclosureGroup(isExpanded: Binding(
                    get: { appState.expandedWorkspaceIDs.contains(workspaceID) },
                    set: { isExpanded in
                        if isExpanded {
                            appState.expandedWorkspaceIDs.insert(workspaceID)
                        } else {
                            appState.expandedWorkspaceIDs.remove(workspaceID)
                        }
                    }
                )) {
                    let chats = workspace.chats
                        .filter { !$0.isArchived || $0.isActive }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    ForEach(chats) { chat in
                        ChatSidebarRow(chat: chat)
                            .tag(chat)
                    }
                    .onMove { source, destination in
                        withAnimation {
                            var newOrder = chats
                            newOrder.move(fromOffsets: source, toOffset: destination)
                            workspace.reorderChats(newOrder)
                        }
                    }
                } label: {
                    WorkspaceRow(workspace: workspace)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 16)
                    .scaleEffect(1.2) 
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(DoubleClickRecognizer {
                        let chat = workspace.addChat(provider: defaultChatMode, permissionMode: defaultPermissionMode)
                        appState.expandedWorkspaceIDs.insert(workspaceID)
                        appState.selectedChat = chat
                    })
                    .onTapGesture {
                        withAnimation {
                            if appState.expandedWorkspaceIDs.contains(workspaceID) {
                                appState.expandedWorkspaceIDs.remove(workspaceID)
                            } else {
                                appState.expandedWorkspaceIDs.insert(workspaceID)
                                if !workspace.chats.contains(where: { !$0.isArchived }) {
                                    let chat = workspace.addChat(provider: defaultChatMode, permissionMode: defaultPermissionMode)
                                    appState.selectedChat = chat
                                }
                            }
                        }
                    }
                }
            }
            .onMove { source, destination in
                withAnimation {
                    let visible = visibleWorkspaces
                    let visibleIDs = Set(visible.map { $0.id })
                    let slots = store.workspaces.indices.filter { visibleIDs.contains(store.workspaces[$0].id) }

                    var newVisible = visible
                    newVisible.move(fromOffsets: source, toOffset: destination)

                    var newAll = store.workspaces
                    for (slot, ws) in zip(slots, newVisible) {
                        newAll[slot] = ws
                    }
                    store.reorderWorkspaces(newAll)
                }
            }
        }
        // .listStyle(.inset)
        // .scrollContentBackground(.hidden)
        .environment(\.sidebarRowSize, .medium)
        .safeAreaBar(edge: .bottom) {
            HStack(spacing: 0) {
                Button {
                    chooseDirectoryForNewWorkspace()
                } label: {
                    Label("New Workspace", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !hideSettingsButton {
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func chooseDirectoryForNewWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a directory for the new workspace"
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let existing = store.workspaces.first(where: { $0.directory == url.path }) {
            existing.isArchived = false
            appState.expandedWorkspaceIDs.insert("w:\(existing.id.uuidString)")
            if let chat = existing.chats.sorted(by: { $0.date > $1.date }).first {
                chat.isArchived = false
                appState.selectedChat = chat
            }
            store.scheduleSave()
            return
        }

        let name = URL(fileURLWithPath: url.path).lastPathComponent
        let workspace = Workspace(name: name, directory: url.path)
        workspace.detectProjectType()
        store.addWorkspace(workspace)
        appState.expandedWorkspaceIDs.insert("w:\(workspace.id.uuidString)")
        let chat = workspace.addChat(provider: defaultChatMode, permissionMode: defaultPermissionMode)
        appState.selectedChat = chat
    }
}

private struct DoubleClickRecognizer: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DetectorView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DetectorView)?.action = action
    }

    final class DetectorView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self = self,
                      let window = self.window,
                      event.window === window,
                      event.clickCount == 2
                else { return event }
                let pointInView = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(pointInView) {
                    self.action?()
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
