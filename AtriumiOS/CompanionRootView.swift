import SwiftUI

struct CompanionRootView: View {
    @Environment(CompanionClient.self) private var client
    @State private var selectedTaskID: String?
    @State private var detailPath: [Route] = []
    /// Shown only after a short delay, so a quick reconnect after waking
    /// doesn't flash a spinner over the cached screens.
    @State private var showReconnecting = false

    var body: some View {
        Group {
            if client.isPaired {
                // Tasks in the sidebar and the selected task in the detail column on
                // iPad; on iPhone the split view collapses into a single stack.
                NavigationSplitView {
                    TasksScreen(selection: $selectedTaskID)
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
        .onChange(of: client.isPaired) { _, isPaired in
            if !isPaired { selectedTaskID = nil }
        }
        .overlay {
            if showReconnecting {
                ReconnectingOverlay(hostName: client.pairedHostName ?? "your Mac", onUnpair: client.unpair)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: showReconnecting)
        .task(id: client.isReconnecting) {
            guard client.isReconnecting else {
                showReconnecting = false
                return
            }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            showReconnecting = true
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
