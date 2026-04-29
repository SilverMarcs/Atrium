import SwiftUI

struct ChatsScreen: View {
    let workspace: WireWorkspace
    @Environment(CompanionClient.self) private var client
    @State private var showingArchived = false
    @State private var searchText = ""

    var body: some View {
        List {
            Section("Active") {
                if filteredActive.isEmpty {
                    Text(searchText.isEmpty ? "No active chats" : "No matches")
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredActive) { chat in
                    NavigationLink(value: Route.chat(chat.id)) {
                        ChatRow(chat: chat)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        archiveButton(for: chat)
                        if chat.isActive {
                            disconnectButton(for: chat)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        deleteButton(for: chat)
                    }
                }
            }
            if showingArchived || (isSearching && !filteredArchived.isEmpty) {
                Section("Archived") {
                    if filteredArchived.isEmpty {
                        Text(searchText.isEmpty ? "No archived chats" : "No matches")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filteredArchived) { chat in
                        NavigationLink(value: Route.chat(chat.id)) {
                            ChatRow(chat: chat)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            archiveButton(for: chat)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            deleteButton(for: chat)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { client.requestSessionsList() }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search chats")
        .navigationTitle(workspace.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ArchiveFilterButton(showingArchived: $showingArchived)
            }
            ToolbarItem(placement: .bottomBar) {
                WorkspaceToolsMenu(workspaceId: workspace.id)
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                NewChatMenu(workspaceId: workspace.id)
            }
        }
    }

    @ViewBuilder
    private func archiveButton(for chat: WireSessionMeta) -> some View {
        Button {
            client.toggleArchive(sessionId: chat.id)
        } label: {
            Label(
                chat.isArchived ? "Unarchive" : "Archive",
                systemImage: chat.isArchived ? "tray.and.arrow.up" : "archivebox"
            )
        }
        .tint(.orange)
    }

    @ViewBuilder
    private func disconnectButton(for chat: WireSessionMeta) -> some View {
        Button {
            client.disconnectChat(sessionId: chat.id)
        } label: {
            Label("Disconnect", systemImage: "bolt.slash")
        }
        .tint(.gray)
    }

    @ViewBuilder
    private func deleteButton(for chat: WireSessionMeta) -> some View {
        Button(role: .destructive) {
            client.deleteChat(sessionId: chat.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var liveChats: [WireSessionMeta] {
        client.workspaces.first { $0.id == workspace.id }?.sessions ?? workspace.sessions
    }

    private var filteredActive: [WireSessionMeta] {
        applySearch(liveChats.filter { !$0.isArchived || $0.isActive })
    }

    private var filteredArchived: [WireSessionMeta] {
        applySearch(liveChats.filter { $0.isArchived && !$0.isActive })
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applySearch(_ chats: [WireSessionMeta]) -> [WireSessionMeta] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return chats }
        return chats.filter { $0.title.localizedStandardContains(query) }
    }
}
