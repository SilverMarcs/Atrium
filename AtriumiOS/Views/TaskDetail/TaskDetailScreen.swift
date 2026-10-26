import SwiftUI

/// One task's conversation, with a prompt field that sends to its agent on the Mac.
struct TaskDetailScreen: View {
    @Environment(CompanionClient.self) private var client
    let taskID: String
    @State private var showingScratchPad = false
    @State private var showingDetails = false
    @State private var taskToRename: WireTask?
    @State private var taskToDelete: WireTask?
    @State private var draft = ""
    @State private var isComposing = false

    private var task: WireTask? { client.task(taskID) }

    var body: some View {
        Group {
            if let task {
                TaskChatView(task: task)
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
                        Divider()
                        Button("Details", systemImage: "info.circle") { showingDetails = true }
                        if task.workspaceID != nil {
                            Button("Scratch Pad", systemImage: "note.text") { showingScratchPad = true }
                        }
                    } label: {
                        Label("Info", systemImage: "info")
                    }
                }
            }
            if let workspaceID = task?.workspaceID {
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink(value: Route.commands(workspaceID)) {
                        Label("Commands", systemImage: "terminal")
                    }
                }
                ToolbarSpacer(.fixed, placement: .bottomBar)
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            if let task, task.actions.contains(.interrupt) {
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) {
                        client.send(.interrupt(taskID: task.id))
                    }
                    .tint(.red)
                }
            } else if let workspaceID = task?.workspaceID {
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink(value: Route.sourceControl(workspaceID)) {
                        Label("Source Control", systemImage: "arrow.triangle.branch")
                    }
                }
            }
        }
        .searchable(text: $draft, isPresented: $isComposing, prompt: "Ask anything…")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .onSubmit(of: .search, sendDraft)
        .sheet(isPresented: $showingDetails) {
            if let task { TaskDetailsSheet(task: task) }
        }
        .sheet(isPresented: $showingScratchPad) {
            if let workspaceID = task?.workspaceID {
                ScratchPadSheet(workspaceID: workspaceID)
            }
        }
        .taskConfirmations(rename: $taskToRename, delete: $taskToDelete)
        .task(id: taskID) {
            await client.follow(.transcript(taskID: taskID))
        }
        .task(id: task?.hasUnreadResult) {
            // Viewing a finished task reads it, as selecting it does on the Mac.
            if let task, task.hasUnreadResult, task.actions.contains(.markRead) {
                client.send(.task(id: task.id, action: .markRead))
            }
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let task, !text.isEmpty else { return }
        guard task.actions.contains(.prompt) else {
            client.actionError = task.status == .waiting
                ? "\(task.provider.name) is waiting for an answer. Reply on your Mac."
                : "\(task.provider.name) can’t take a prompt right now."
            return
        }
        draft = ""
        isComposing = false
        client.send(.prompt(taskID: task.id, text: text))
    }
}
