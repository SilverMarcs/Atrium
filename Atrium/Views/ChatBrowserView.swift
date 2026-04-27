import SwiftUI

struct ChatBrowserView: View {
    let workspace: Workspace

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultChatMode") private var defaultChatMode: AgentProvider = .claude
    @AppStorage("defaultPermissionMode") private var defaultPermissionMode: PermissionMode = .bypassPermissions

    private var regularChats: [Chat] {
        workspace.chats.filter { !$0.isArchived }.sorted { $0.date > $1.date }
    }

    private var archivedChats: [Chat] {
        workspace.chats.filter { $0.isArchived }.sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                if !regularChats.isEmpty {
                    ForEach(regularChats) { chat in
                        ChatBrowserRow(chat: chat, workspace: workspace)
                    }
                }

                if !archivedChats.isEmpty {
                    Section("Archived") {
                        ForEach(archivedChats) { chat in
                            ChatBrowserRow(chat: chat, workspace: workspace)
                        }
                    }
                }
            }
            .overlay {
                if workspace.chats.isEmpty {
                    ContentUnavailableView {
                        Label("No Chats", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Start a new chat to begin.")
                    } actions: {
                        newChatButton
                    }
                }
            }
            .navigationTitle(workspace.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    newChatButton
                }
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    private var newChatButton: some View {
        Menu {
            ForEach(AgentProvider.allCases, id: \.self) { provider in
                Button {
                    let chat = workspace.addChat(provider: provider, permissionMode: defaultPermissionMode)
                    appState.expandedWorkspaceIDs.insert("w:\(workspace.id.uuidString)")
                    appState.selectedChat = chat
                    dismiss()
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
            dismiss()
        }
    }

    static func shortRelative(from date: Date, now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "now" }

        let components = Calendar.current.dateComponents(
            [.month, .weekOfYear, .day, .hour, .minute],
            from: date,
            to: now
        )

        var parts: [String] = []
        let pairs: [(Int?, String)] = [
            (components.month, "mo"),
            (components.weekOfYear, "w"),
            (components.day, "d"),
            (components.hour, "h"),
            (components.minute, "m")
        ]
        for (value, suffix) in pairs {
            guard parts.count < 2, let v = value, v > 0 else { continue }
            parts.append("\(v)\(suffix)")
        }

        if parts.isEmpty { return "now" }
        return parts.joined(separator: " ") + " ago"
    }

}
