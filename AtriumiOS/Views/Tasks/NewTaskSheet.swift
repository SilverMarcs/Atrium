import SwiftUI

/// Starts a task on the host in a chosen project with a chosen agent, then opens it.
struct NewTaskSheet: View {
    @Environment(CompanionClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AgentProvider?
    @State private var workspaceID: UUID?
    @State private var searchText = ""
    @State private var isCreating = false

    private var providers: [WireProvider] {
        client.tasks?.providers.filter(\.isEnabled) ?? []
    }

    private var workspaces: [WireWorkspace] {
        let all = client.tasks?.workspaces ?? []
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedStandardContains(searchText) || $0.directory.localizedStandardContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Project") {
                    ForEach(workspaces) { workspace in
                        ProjectRow(workspace: workspace, isSelected: workspace.id == workspaceID) {
                            workspaceID = workspace.id
                        }
                    }
                }
            }
            // Projects reordered on the host slide into place.
            .animation(.default, value: workspaces.map(\.id))
            .searchable(text: $searchText, prompt: "Search projects")
            .navigationTitle(provider?.name ?? "New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Picker("Agent", selection: $provider) {
                    ForEach(providers) { provider in
                        Label {
                            Text(provider.provider.name)
                        } icon: {
                            ProviderIcon(provider: provider.provider)
                        }
                        .tag(Optional(provider.provider))
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Start", role: .confirm, action: create)
                            .disabled(provider == nil || workspaceID == nil)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isCreating)
        .onAppear {
            provider = provider ?? providers.first?.provider
            workspaceID = workspaceID ?? client.tasks?.workspaces.first?.id
        }
    }

    private func create() {
        guard let provider, let workspaceID else { return }
        isCreating = true
        Task {
            defer { isCreating = false }
            guard case .task(let id) = await client.perform(.compose(provider: provider, workspaceID: workspaceID)) else { return }
            dismiss()
            client.pendingTaskID = id
        }
    }
}
