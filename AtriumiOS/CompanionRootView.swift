import SwiftUI

struct CompanionRootView: View {
    @Environment(CompanionClient.self) private var client
    @State private var dictationSettings = DictationSettings()
    @State private var selectedTaskID: String?
    @State private var navigationHostID: String?
    /// The task the detail column keeps showing once going back on iPhone has
    /// cleared the selection. See `detailTaskID`.
    @State private var lastSelectedTaskID: String?
    @State private var detailPath: [Route] = []
    @State private var showingHosts = false

    var body: some View {
        Group {
            if client.isPaired {
                // Tasks in the sidebar and the selected task in the detail column on
                // iPad; on iPhone the split view collapses into a single stack.
                NavigationSplitView {
                    TasksScreen(selection: $selectedTaskID) { showingHosts = true }
                        .navigationSplitViewColumnWidth(min: 300, ideal: 340)
                } detail: {
                    NavigationStack(path: $detailPath) {
                        Group {
                            if let detailTaskID {
                                TaskDetailScreen(taskID: detailTaskID)
                            } else {
                                ContentUnavailableView("No Task Selected", systemImage: "sidebar.left")
                            }
                        }
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .sourceControl(let workspaceID):
                                SourceControlScreen(workspaceID: workspaceID)
                            case .fileDiff(let workspaceID, let file, let isStaged):
                                FileDiffScreen(workspaceID: workspaceID, file: file, isStaged: isStaged)
                            case .commands(let workspaceID):
                                CommandsScreen(workspaceID: workspaceID)
                            }
                        }
                    }
                }
            } else {
                NavigationStack {
                    PairingScreen()
                }
            }
        }
        .environment(dictationSettings)
        .onOpenURL { url in client.handle(url) }
        .task(id: client.isPaired) {
            guard client.isPaired else { return }
            await client.follow(.tasks)
        }
        .onChange(of: selectedTaskID) { _, id in
            if let id {
                // A draft is forgotten once another task opens. Going back on
                // iPhone keeps it, since its screen stays in the detail column.
                if let lastSelectedTaskID, lastSelectedTaskID != id { client.closeDraft(lastSelectedTaskID) }
                lastSelectedTaskID = id
            }
            detailPath = []
        }
        .onChange(of: [client.currentHost?.id, client.pendingTaskID], initial: true) {
            if navigationHostID != client.currentHost?.id {
                navigationHostID = client.currentHost?.id
                selectedTaskID = nil
                lastSelectedTaskID = nil
                detailPath = []
            }
            if let id = client.pendingTaskID {
                selectedTaskID = id
                detailPath = []
                client.pendingTaskID = nil
            }
        }
        .sheet(isPresented: $showingHosts) {
            HostsSheet()
                .environment(dictationSettings)
        }
        .alert(
            "Couldn’t Complete Action",
            isPresented: Binding(get: { client.actionError != nil }, set: { if !$0 { client.actionError = nil } })
        ) {
            Button("OK") { client.actionError = nil }
        } message: {
            Text(client.actionError ?? "")
        }
    }

    /// Going back on iPhone clears the selection, but the detail column keeps
    /// the last task's screen rather than swapping in a placeholder. Opening a
    /// task then updates that screen in place: a screen swapped in while the
    /// collapsed split view pushes the column is attached twice, so its tasks
    /// run twice (subscribing, unsubscribing and resubscribing to the
    /// transcript, and marking it read twice) and its search-field composer is
    /// installed twice, bouncing the bottom bar.
    private var detailTaskID: String? {
        selectedTaskID ?? lastSelectedTaskID
    }
}
