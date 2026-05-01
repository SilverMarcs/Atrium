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
        HStack(spacing: 6) {
            Label {
                Text(workspace.name)
                    .lineLimit(1)
            } icon: {
                if let nsImage = customIconImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                        .clipShape(.rect(cornerRadius: 6))
                } else if workspace.projectType != .unknown {
                    Image(workspace.projectType.iconName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "folder")
                }
            }

            Spacer(minLength: 4)

            if workspace.hasActiveChildProcess {
                Image(systemName: "terminal.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }

            ForEach(displayedProviders, id: \.self) { provider in
                Image(provider.imageName)
                    .foregroundStyle(provider.color)
                    .symbolEffect(.pulse, isActive: notificationProviders.contains(provider))
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
            
            Menu {
                ForEach(ProjectType.allCases, id: \.self) { type in
                    Button {
                        workspace.projectType = type
                    } label: {
                        Label {
                            Text(type.displayName)
                        } icon: {
                            if workspace.projectType == type {
                                Image(systemName: "checkmark")
                            } else if !type.iconName.isEmpty {
                                Image(type.iconName)
                            }
                        }
                    }
                }
                
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
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                toggleArchive()
            } label: {
                Label(
                    workspace.isArchived ? "Unarchive" : "Archive",
                    systemImage: workspace.isArchived ? "tray.and.arrow.up" : "archivebox"
                )
            }
            .labelStyle(.iconOnly)
            .tint(.orange)
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