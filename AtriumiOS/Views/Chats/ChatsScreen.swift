import SwiftUI

struct ChatsScreen: View {
    let workspace: WireWorkspace
    @Environment(CompanionClient.self) private var client
    @State private var showingArchived = false

    var body: some View {
        List {
            Section("Active") {
                if activeChats.isEmpty {
                    Text("No active chats")
                        .foregroundStyle(.secondary)
                }
                ForEach(activeChats) { chat in
                    NavigationLink(value: chat.id) {
                        ChatRow(chat: chat)
                    }
                }
            }
            if showingArchived {
                Section("Archived") {
                    if archivedChats.isEmpty {
                        Text("No archived chats")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(archivedChats) { chat in
                        NavigationLink(value: chat.id) {
                            ChatRow(chat: chat)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { client.requestSessionsList() }
        .navigationTitle(workspace.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ArchiveFilterButton(showingArchived: $showingArchived)
            }
        }
        .navigationDestination(for: UUID.self) { sessionId in
            SessionDetailScreen(sessionId: sessionId)
        }
    }

    /// Chats are read from the live `client.workspaces` list rather than the
    /// snapshot passed in at navigation time so list updates from the host
    /// (new turns, title changes) reflect immediately.
    private var liveChats: [WireSessionMeta] {
        client.workspaces.first { $0.id == workspace.id }?.sessions ?? workspace.sessions
    }

    private var activeChats: [WireSessionMeta] {
        liveChats.filter { !$0.isArchived }
    }

    private var archivedChats: [WireSessionMeta] {
        liveChats.filter { $0.isArchived }
    }
}
