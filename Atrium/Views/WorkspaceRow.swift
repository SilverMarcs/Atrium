import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WorkspaceRow: View {
    @Environment(AppState.self) private var appState
    @Environment(WorkspaceStore.self) private var store
    @AppStorage("defaultChatMode") private var defaultChatMode: AgentProvider = .claude
    @AppStorage("defaultPermissionMode") private var defaultPermissionMode: PermissionMode = .bypassPermissions

    let workspace: Workspace

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isBrowsingChats = false

    private var isExpanded: Bool {
        appState.expandedWorkspaceIDs.contains("w:\(workspace.id.uuidString)")
    }

    private var notificationProviders: Set<AgentProvider> {
        let selectedID = appState.selectedChat?.id
        return Set(workspace.chats.lazy
            .filter { !$0.isArchived && $0.hasNotification && $0.id != selectedID }
            .map { $0.provider })
    }

    private var processingProviders: Set<AgentProvider> {
        Set(workspace.chats.lazy
            .filter { !$0.isArchived && $0.session.isProcessing }
            .map { $0.provider })
    }

    private var displayedProviders: [AgentProvider] {
        guard !isExpanded else { return [] }
        var seen = Set<AgentProvider>()
        var result: [AgentProvider] = []
        for chat in workspace.chats where !chat.isArchived && chat.isActive {
            if seen.insert(chat.provider).inserted {
                result.append(chat.provider)
            }
        }
        for provider in AgentProvider.allCases
        where notificationProviders.contains(provider) && seen.insert(provider).inserted {
            result.append(provider)
        }
        return result
    }

    private var customIconImage: NSImage? {
        guard let url = workspace.customIconURL else { return nil }
        return NSImage(contentsOf: url)
    }


    var body: some View {
        HStack(spacing: 5) {
            Label {
                Text(workspace.name)
                    .lineLimit(1)
            } icon: {
                if let nsImage = customIconImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .clipShape(.rect(cornerRadius: 6))
                } else if workspace.projectType != .unknown {
                    Image(workspace.projectType.iconName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "folder")
                }
            }

            Spacer(minLength: 4)

            if !workspace.scratchPad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    openScratchPad()
                } label: {
                    Image(systemName: "note.text")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if workspace.hasActiveChildProcess {
                Button {
                    openCommands()
                } label: {
                    Image(systemName: "terminal.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ForEach(displayedProviders, id: \.self) { provider in
                Button {
                    selectChat(for: provider)
                } label: {
                    Image(provider.imageName)
                        .foregroundStyle(notificationProviders.contains(provider) ? Color.red : provider.color)
                        .imageScale(.small)
                        .symbolEffect(.pulse, isActive: processingProviders.contains(provider))
                }
                .buttonStyle(.plain)
            }
        }
        .alert("Rename Workspace", isPresented: $isRenaming) {
            TextField("Workspace Name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if !renameText.isEmpty {
                    workspace.name = renameText
                }
            }
        }
        .contextMenu {
            Menu {
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                    Button {
                        let chat = workspace.addChat(provider: provider, permissionMode: defaultPermissionMode)
                        appState.expandedWorkspaceIDs.insert("w:\(workspace.id.uuidString)")
                        appState.selectedChat = chat
                    } label: {
                        Label(provider.rawValue, image: provider.imageName)
                    }
                }
            } label: {
                Label("New Chat", systemImage: "plus")
            } primaryAction: {
                let chat = workspace.addChat(provider: defaultChatMode, permissionMode: defaultPermissionMode)
                appState.expandedWorkspaceIDs.insert("w:\(workspace.id.uuidString)")
                appState.selectedChat = chat
            }

            Button {
                isBrowsingChats = true
            } label: {
                Label("Browse Chats", systemImage: "list.bullet")
            }

            Divider()

            RenameButton()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([workspace.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Divider()

            Menu {
                Picker("Project Type", selection: Bindable(workspace).projectType) {
                    ForEach(ProjectType.allCases, id: \.self) { type in
                        Label {
                            Text(type.displayName)
                        } icon: {
                            if !type.iconName.isEmpty {
                                Image(type.iconName)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 18, height: 18)
                            }
                        }
                        .tag(type)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Divider()

                Button("Auto-Detect") {
                    workspace.detectProjectType()
                }
            } label: {
                Label("Project Type", systemImage: "shippingbox")
            }

            Button {
                chooseCustomIcon()
            } label: {
                Label("Choose Icon…", systemImage: "photo")
            }

            if workspace.customIconFilename != nil {
                Button {
                    workspace.clearCustomIcon()
                } label: {
                    Label("Reset Icon", systemImage: "arrow.uturn.backward")
                }
            }

            Divider()
            Button {
                workspace.disconnectAllActiveChats()
            } label: {
                Label("Disconnect All Chats", systemImage: "bolt.slash")
            }
            .disabled(!workspace.hasActiveChats)

            Button {
                workspace.killAllRunningTerminals()
            } label: {
                Label("Kill All Terminals", systemImage: "xmark.octagon")
            }
            .disabled(!workspace.hasRunningTerminals)

            Divider()
            Button {
                toggleArchive()
            } label: {
                Label(
                    workspace.isArchived ? "Unarchive" : "Archive",
                    systemImage: workspace.isArchived ? "tray.and.arrow.up" : "archivebox"
                )
            }

            Button(role: .destructive) {
                if appState.selectedChat?.workspace === workspace {
                    appState.selectedChat = nil
                }
                store.deleteWorkspace(workspace)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .renameAction {
            renameText = workspace.name
            isRenaming = true
        }
        .sheet(isPresented: $isBrowsingChats) {
            ChatBrowserView(workspace: workspace)
        }
    }

    private func chooseCustomIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.icns, .png, .jpeg]
        panel.message = "Choose an icon image"
        panel.prompt = "Set Icon"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try workspace.setCustomIcon(from: url)
        } catch {
            print("WorkspaceRow: failed to set custom icon: \(error)")
        }
    }

    @discardableResult
    private func ensureSelectedChat() -> Chat {
        appState.expandedWorkspaceIDs.insert("w:\(workspace.id.uuidString)")
        if let active = workspace.chats.last(where: { !$0.isArchived && $0.isActive }) {
            appState.selectedChat = active
            return active
        }
        if let recent = workspace.chats.last(where: { !$0.isArchived }) {
            appState.selectedChat = recent
            return recent
        }
        let chat = workspace.addChat(provider: defaultChatMode, permissionMode: defaultPermissionMode)
        appState.selectedChat = chat
        return chat
    }

    private func openCommands() {
        ensureSelectedChat()
        workspace.inspectorState.selectedTab = .commands
    }

    private func openScratchPad() {
        ensureSelectedChat()
        appState.scratchPadRequest = workspace
    }

    private func selectChat(for provider: AgentProvider) {
        if let chat = workspace.chats.last(where: { !$0.isArchived && $0.provider == provider }) {
            appState.expandedWorkspaceIDs.insert("w:\(workspace.id.uuidString)")
            appState.selectedChat = chat
        } else {
            ensureSelectedChat()
        }
    }

    private func toggleArchive() {
        if !workspace.isArchived {
            if appState.selectedChat?.workspace === workspace {
                appState.selectedChat = nil
            }
            workspace.disconnectAllActiveChats()
            workspace.killAllRunningTerminals()
        }
        workspace.isArchived.toggle()
    }
}