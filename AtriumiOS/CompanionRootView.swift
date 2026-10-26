import SwiftUI

struct CompanionRootView: View {
    @Environment(CompanionClient.self) private var client
    @State private var selectedTaskID: String?
    @State private var detailPath: [Route] = []
    @State private var showingMacs = false

    var body: some View {
        Group {
            if client.isPaired {
                // Tasks in the sidebar and the selected task in the detail column on
                // iPad; on iPhone the split view collapses into a single stack.
                NavigationSplitView {
                    TasksScreen(selection: $selectedTaskID) { showingMacs = true }
                        .navigationSplitViewColumnWidth(min: 300, ideal: 340)
                } detail: {
                    NavigationStack(path: $detailPath) {
                        Group {
                            if let selectedTaskID {
                                TaskDetailScreen(taskID: selectedTaskID)
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
        .onOpenURL { url in client.handle(url) }
        .task(id: client.isPaired) {
            guard client.isPaired else { return }
            await client.follow(.tasks)
        }
        .onChange(of: selectedTaskID) {
            detailPath = []
        }
        .onChange(of: client.pendingTaskID) { _, id in
            guard let id else { return }
            selectedTaskID = id
            client.pendingTaskID = nil
        }
        .onChange(of: client.currentMac) {
            // Another Mac's tasks replace this one's.
            selectedTaskID = nil
        }
        .sheet(isPresented: $showingMacs) {
            MacsSheet()
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
}
