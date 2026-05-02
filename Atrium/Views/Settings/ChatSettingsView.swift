import SwiftUI

struct ChatSettingsView: View {
    @AppStorage("defaultChatMode") private var defaultChatMode: AgentProvider = .claude
    @AppStorage("defaultPermissionMode") private var defaultPermissionMode: PermissionMode = .bypassPermissions

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
                    ForEach(PermissionMode.allCases) { mode in
                        Text(mode.label)
                            .tag(mode)
                    }
                } label: {
                    Text("Default Permission Mode")
                    Text(defaultPermissionMode.description)
                }
            }

            Section("Models") {
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                    LabeledContent {
                        Text(modelSummary(for: provider))
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(provider.rawValue, image: provider.imageName)
                    }
                }
            }
            .sectionActions {
                Button {
                    catalog.refreshAll()
                } label: {
                    if catalog.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Refresh")
                    }
                }
                .disabled(catalog.isRefreshing)
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

    private func modelSummary(for provider: AgentProvider) -> String {
        let count = catalog.models(for: provider).count
        if catalog.isRefreshing(provider: provider) && count == 0 {
            return "Loading…"
        }
        if count == 0 { return "Not loaded" }
        return count == 1 ? "1 model" : "\(count) models"
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
