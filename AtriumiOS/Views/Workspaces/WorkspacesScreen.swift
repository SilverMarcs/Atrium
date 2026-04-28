import SwiftUI

struct WorkspacesScreen: View {
    @Environment(CompanionClient.self) private var client
    @State private var showingArchived = false
    @State private var searchText = ""

    var body: some View {
        List {
            Section("Active") {
                if filteredActive.isEmpty {
                    Text(searchText.isEmpty ? "No active workspaces" : "No matches")
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredActive) { workspace in
                    NavigationLink(value: Route.workspace(workspace)) {
                        WorkspaceRow(workspace: workspace)
                    }
                }
            }
            if showingArchived {
                Section("Archived") {
                    if filteredArchived.isEmpty {
                        Text(searchText.isEmpty ? "No archived workspaces" : "No matches")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filteredArchived) { workspace in
                        NavigationLink(value: Route.workspace(workspace)) {
                            WorkspaceRow(workspace: workspace)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { client.requestSessionsList() }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search workspaces")
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
            if client.isReconnecting {
                ToolbarItem(placement: .principal) {
                    Text("Reconnecting…")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ArchiveFilterButton(showingArchived: $showingArchived)
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
        }
    }

    private var filteredActive: [WireWorkspace] {
        applySearch(client.workspaces.filter { !$0.isArchived })
    }

    private var filteredArchived: [WireWorkspace] {
        applySearch(client.workspaces.filter { $0.isArchived })
    }

    private func applySearch(_ workspaces: [WireWorkspace]) -> [WireWorkspace] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workspaces }
        return workspaces.filter { ws in
            ws.name.localizedStandardContains(query)
                || ws.sessions.contains { $0.title.localizedStandardContains(query) }
        }
    }
}
