import SwiftUI

struct WorkspacesScreen: View {
    @Environment(CompanionClient.self) private var client
    @State private var showingArchived = false

    var body: some View {
        List {
            Section("Active") {
                if activeWorkspaces.isEmpty {
                    Text("No active workspaces")
                        .foregroundStyle(.secondary)
                }
                ForEach(activeWorkspaces) { workspace in
                    NavigationLink(value: workspace) {
                        WorkspaceRow(workspace: workspace)
                    }
                }
            }
            if showingArchived {
                Section("Archived") {
                    if archivedWorkspaces.isEmpty {
                        Text("No archived workspaces")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(archivedWorkspaces) { workspace in
                        NavigationLink(value: workspace) {
                            WorkspaceRow(workspace: workspace)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { client.requestSessionsList() }
        .navigationTitle("Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .cancel) {
                    client.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "power")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ArchiveFilterButton(showingArchived: $showingArchived)
            }
        }
        .navigationDestination(for: WireWorkspace.self) { workspace in
            ChatsScreen(workspace: workspace)
        }
    }

    private var activeWorkspaces: [WireWorkspace] {
        client.workspaces.filter { !$0.isArchived }
    }

    private var archivedWorkspaces: [WireWorkspace] {
        client.workspaces.filter { $0.isArchived }
    }
}
