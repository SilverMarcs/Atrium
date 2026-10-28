import SwiftUI

/// Picks a host and project for a new task, then opens it as a draft, whose
/// empty chat picks the agent. The host creates the task once its first prompt
/// is sent.
struct NewTaskSheet: View {
    @Environment(HostDirectory.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    /// Opens a draft in the chosen project.
    let onStart: (WorkspaceRef) -> Void
    @State private var hostID: String?
    @State private var workspaceID: UUID?
    @State private var searchText = ""

    private var host: HostClient? { hosts.host(hostID) }

    private var workspaces: [WireWorkspace] {
        let all = host?.tasks?.workspaces ?? []
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedStandardContains(searchText) || $0.directory.localizedStandardContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                if hosts.hosts.count > 1 {
                    Section("Host") {
                        Picker("Host", selection: $hostID) {
                            ForEach(hosts.hosts.filter(\.isConnected)) { host in
                                Text(host.name).tag(Optional(host.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                Section("Project") {
                    if let host {
                        ForEach(workspaces) { workspace in
                            ProjectRow(workspace: workspace, host: host, isSelected: workspace.id == workspaceID) {
                                workspaceID = workspace.id
                            }
                        }
                    }
                }
            }
            // Projects reordered on the host slide into place.
            .animation(.default, value: workspaces.map(\.id))
            .searchable(text: $searchText, prompt: "Search projects")
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", role: .confirm, action: start)
                        .disabled(host?.defaultProvider == nil || workspaceID == nil)
                }
            }
        }
        .onAppear {
            hostID = hostID ?? hosts.visibleHosts.first(where: \.isConnected)?.id
            workspaceID = workspaceID ?? host?.tasks?.workspaces.first?.id
        }
        .onChange(of: hostID) { old, _ in
            guard old != nil else { return }
            workspaceID = host?.tasks?.workspaces.first?.id
        }
    }

    private func start() {
        guard let host, let workspaceID else { return }
        dismiss()
        onStart(WorkspaceRef(hostID: host.id, workspaceID: workspaceID))
    }
}
