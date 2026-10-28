import SwiftUI
import UniformTypeIdentifiers

/// Picks a project on any connected host for a new task, then opens it as a
/// draft, whose empty chat picks the agent. The host creates the task once its
/// first prompt is sent.
struct ComposeThreadView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var hostID: String?
    @State private var workspaceID: UUID?
    @State private var showingProjectPicker = false
    @State private var projectPicker = ComposeProjectPickerModel()

    private var host: HostClient? { app.hosts.host(hostID) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                if app.hosts.hosts.count > 1 {
                    HStack {
                        Picker("Host", selection: $hostID) {
                            ForEach(app.hosts.hosts.filter(\.isConnected)) { host in
                                Text(host.name).tag(Optional(host.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.large)
                        .fixedSize()
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                }

                if let host {
                    ComposeProjectPickerView(host: host, workspaceID: $workspaceID, model: projectPicker, onSubmit: openTask)
                }
            }
            .toolbar {
                if host?.isLocal == true {
                    ToolbarItem(placement: .automatic) {
                        Button("Add Folder…", systemImage: "folder.badge.plus") { showingProjectPicker = true }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", role: .close) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("New Task", role: .confirm, action: openTask)
                        .keyboardShortcut(.defaultAction)
                        .disabled(workspaceID == nil || host?.defaultProvider == nil)
                }
            }
        }
        .frame(width: 420, height: 460)
        .alert("Couldn’t Add Project", isPresented: Binding(
            get: { app.hosts.actionError != nil },
            set: { if !$0 { app.hosts.actionError = nil } }
        )) {
            Button("OK") { app.hosts.actionError = nil }
        } message: {
            Text(app.hosts.actionError ?? "")
        }
        .fileImporter(isPresented: $showingProjectPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { addProject(url) }
        }
        .onAppear {
            let current = app.selectedTask
            hostID = current?.host.id ?? app.hosts.visibleHosts.first(where: \.isConnected)?.id
            workspaceID = app.selectedProject?.workspaceID ?? host?.tasks?.workspaces.first?.id
        }
        .onChange(of: hostID) { old, _ in
            guard old != nil else { return }
            workspaceID = host?.tasks?.workspaces.first?.id
        }
    }

    private func openTask() {
        guard let host, let workspaceID else { return }
        app.hosts.openDraft(in: WorkspaceRef(hostID: host.id, workspaceID: workspaceID))
        dismiss()
    }

    private func addProject(_ url: URL) {
        projectPicker.searchText = ""
        Task {
            guard case .workspace(let id) = await host?.perform(.addWorkspace(path: url.path(percentEncoded: false))) else { return }
            workspaceID = id
        }
    }
}
