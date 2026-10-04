import SwiftUI

struct ChatSettingsView: View {
    @AppStorage("defaultChatMode") private var defaultChatMode: AgentProvider = .codex
    @AppStorage("defaultPermissionMode") private var defaultPermissionMode: String = ""

    @Environment(WorkspaceStore.self) private var store
    @State private var showDeleteArchivedConfirm = false
    private let catalog = ModelCatalog.shared

    private var archivedChatCount: Int {
        store.workspaces.reduce(0) { $0 + $1.chats.lazy.filter(\.isArchived).count }
    }

    var body: some View {
        Form {
            Section("Defaults") {
                Picker(selection: $defaultChatMode) {
                    ForEach(AgentProvider.allCases, id: \.self) { provider in
                        Label(provider.rawValue, image: provider.imageName)
                            .tag(provider)
                    }
                } label: {
                    Text("Chat Mode")
                    Text("Used when creating a new chat")
                }

                Picker(selection: $defaultPermissionMode) {
                    Text("Provider Default").tag("")
                    ForEach(catalog.permissionModes(for: defaultChatMode)) { mode in
                        Text(mode.label)
                            .tag(mode.rawValue)
                    }
                } label: {
                    Text("Default Permission Mode")
                    Text(catalog.permissionModes(for: defaultChatMode).first { $0.rawValue == defaultPermissionMode }?.description ?? "Use the provider’s configuration")
                }
            }

            Section {
                LabeledContent {
                    Button("Delete", role: .destructive) {
                        showDeleteArchivedConfirm = true
                    }
                    .disabled(archivedChatCount == 0)
                } label: {
                    Text("Delete Archived Chats")
                }
            } footer: {
                Text(archivedChatCount == 1 ? "1 archived chat" : "\(archivedChatCount) archived chats will be deleted")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete \(archivedChatCount) archived chat\(archivedChatCount == 1 ? "" : "s")?",
            isPresented: $showDeleteArchivedConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: deleteArchivedChats)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes all archived chats across every workspace. This action cannot be undone.")
        }
    }

    private func deleteArchivedChats() {
        for workspace in store.workspaces {
            let archived = workspace.chats.filter(\.isArchived)
            for chat in archived {
                workspace.removeChat(chat)
            }
        }
    }
}

#Preview {
    ChatSettingsView()
        .environment(WorkspaceStore())
}
