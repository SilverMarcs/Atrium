import SwiftUI
import UniformTypeIdentifiers

struct ComposeThreadView: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    @Environment(WorkspaceStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(TaskSessionController.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AgentProvider?
    @State private var workspaceID: UUID?
    @State private var showingProjectPicker = false
    @State private var projectPicker = ComposeProjectPickerModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                HStack {
                    Picker("Provider", selection: $provider) {
                        ForEach(integrations.enabledProviders) { provider in
                            Label {
                                Text(provider.name)
                            } icon: {
                                ProviderIcon(provider: provider)
                            }
                            .labelStyle(.titleAndIcon)
                            .tag(Optional(provider))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.large)
                    .fixedSize()
                    Spacer()
                    if sessions.isOpening { ProgressView().controlSize(.small) }
                    Button("Add Project…", systemImage: "folder.badge.plus") { showingProjectPicker = true }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)

                ComposeProjectPickerView(
                    workspaces: store.workspaces,
                    workspaceID: $workspaceID,
                    model: projectPicker,
                    onSubmit: openTask,
                    onMove: { source, destination in
                        withAnimation { store.moveWorkspaces(from: source, to: destination) }
                    },
                    onDelete: store.deleteWorkspace
                )
            }
            .disabled(sessions.isOpening)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", role: .close) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(sessions.isOpening)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("New Task", role: .confirm, action: openTask)
                        .keyboardShortcut(.defaultAction)
                        .disabled(workspaceID == nil || sessions.isOpening || !integrations.enabledProviders.contains(where: { $0 == provider }))
                }
            }
        }
        .frame(width: 420, height: 460)
        .interactiveDismissDisabled(sessions.isOpening)
        .alert("Couldn’t Open Thread", isPresented: Binding(
            get: { integrations.actionError != nil },
            set: { if !$0 { integrations.actionError = nil } }
        )) {
            Button("OK") { integrations.actionError = nil }
        } message: {
            Text(integrations.actionError ?? "")
        }
        .fileImporter(isPresented: $showingProjectPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { addProject(url) }
        }
        .onAppear {
            let currentProvider = appState.selectedSession?.thread.provider
            provider = integrations.enabledProviders.first(where: { $0 == currentProvider })
                ?? integrations.enabledProviders.first
            workspaceID = appState.selectedWorkspace?.id ?? store.workspaces.first?.id
        }
    }

    private func openTask() {
        guard let provider, let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        Task {
            if await sessions.compose(provider: provider, workspace: workspace) != nil { dismiss() }
        }
    }

    private func addProject(_ url: URL) {
        projectPicker.searchText = ""
        if let existing = store.workspaces.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            workspaceID = existing.id
            return
        }
        let workspace = Workspace(name: url.lastPathComponent, directory: url.path)
        workspace.detectProjectType()
        store.addWorkspace(workspace)
        workspaceID = workspace.id
    }
}
