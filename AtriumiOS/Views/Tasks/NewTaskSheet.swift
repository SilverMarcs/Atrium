import SwiftUI

/// Picks a project and an agent for a new task, then opens it as a draft,
/// which the host creates once its first prompt is sent.
struct NewTaskSheet: View {
    @Environment(CompanionClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    /// Opens a draft in the chosen project with the chosen agent.
    let onStart: (UUID, AgentProvider) -> Void
    @State private var provider: AgentProvider?
    @State private var workspaceID: UUID?
    @State private var searchText = ""

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
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Menu {
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
                    } label: {
                        HStack {
                            if let provider {
                                Label {
                                    Text(provider.name)
                                } icon: {
                                    ProviderIcon(provider: provider)
                                }
                                .labelStyle(.titleAndIcon)
                            } else {
                                Text("New Task")
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", role: .confirm, action: start)
                        .disabled(provider == nil || workspaceID == nil)
                }
            }
        }
        .onAppear {
            provider = provider ?? client.defaultProvider
            workspaceID = workspaceID ?? client.tasks?.workspaces.first?.id
        }
    }

    private func start() {
        guard let provider, let workspaceID else { return }
        dismiss()
        onStart(workspaceID, provider)
    }
}
