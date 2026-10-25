import SwiftUI

/// One task. The content area summarizes the task for now and is where its
/// terminal will appear; the toolbars match the companion's other screens.
struct TaskDetailScreen: View {
    @Environment(CompanionClient.self) private var client
    let taskID: String
    @State private var showingScratchPad = false
    @State private var taskToRename: WireTask?
    @State private var taskToDelete: WireTask?
    /// The prompt field from the legacy chat screen. Sending prompts isn't wired up yet.
    @State private var draft = ""
    @State private var isComposing = false

    private var task: WireTask? { client.task(taskID) }

    var body: some View {
        Group {
            if let task {
                TaskSummaryView(task: task)
            } else if client.tasks == nil || client.isReconnecting {
                ProgressView()
                    .controlSize(.large)
            } else {
                ContentUnavailableView(
                    "Task Unavailable",
                    systemImage: "questionmark.bubble",
                    description: Text("It may still be starting, or it was deleted on your Mac.")
                )
            }
        }
        .navigationTitle(task?.title ?? "Task")
        .navigationSubtitle(task?.projectName ?? "")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let task {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        TaskContextMenu(state: task.menuState) { action in
                            switch action {
                            case .rename: taskToRename = task
                            case .delete: taskToDelete = task
                            default: client.perform(action, on: task)
                            }
                        }
                        if task.workspaceID != nil {
                            Divider()
                            Button("Scratch Pad", systemImage: "note.text") { showingScratchPad = true }
                        }
                    } label: {
                        Label("Info", systemImage: "info")
                    }
                }
            }
            if let workspaceID = task?.workspaceID {
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink(value: Route.sourceControl(workspaceID)) {
                        Label("Source Control", systemImage: "arrow.triangle.branch")
                    }
                }
                ToolbarSpacer(.fixed, placement: .bottomBar)
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            if let workspaceID = task?.workspaceID {
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink(value: Route.commands(workspaceID)) {
                        Label("Commands", systemImage: "terminal")
                    }
                }
            }
        }
        .searchable(text: $draft, isPresented: $isComposing, prompt: "Ask anything…")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .onSubmit(of: .search) {
            draft = ""
            isComposing = false
        }
        .sheet(isPresented: $showingScratchPad) {
            if let workspaceID = task?.workspaceID {
                ScratchPadSheet(workspaceID: workspaceID)
            }
        }
        .taskConfirmations(rename: $taskToRename, delete: $taskToDelete)
        .task(id: task?.hasUnreadResult) {
            // Viewing a finished task reads it, as selecting it does on the Mac.
            if let task, task.hasUnreadResult, task.actions.contains(.markRead) {
                client.send(.task(id: task.id, action: .markRead))
            }
        }
    }
}
