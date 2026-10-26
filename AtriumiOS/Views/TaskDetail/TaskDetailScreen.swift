import SwiftUI

/// One task's conversation, with a prompt field that sends to its agent on the host.
struct TaskDetailScreen: View {
    @Environment(CompanionClient.self) private var client
    let taskID: String
    @State private var showingScratchPad = false
    @State private var showingDetails = false
    @State private var taskToRename: WireTask?
    @State private var taskToDelete: WireTask?
    @State private var composer = TaskComposer()
    /// Drafts left in other tasks, restored when their task opens again.
    @State private var stashedComposers: [String: TaskComposer] = [:]

    /// The task's info menu is hidden for now; its actions stay wired up.
    private static let showsInfoMenu = false

    private var task: WireTask? { client.task(taskID) }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

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
                    description: Text("It may still be starting, or it was deleted on your host.")
                )
            }
        }
        .onAppear { client.setVisibleTask(taskID) }
        .onDisappear { client.clearVisibleTask(taskID) }
        .navigationTitle(task?.title ?? "Task")
        // iPad has no More menu, so its subtitle names the model in its place, and
        // leaves the connection status to the task list beside it.
        .modifier(ConnectionStatusSubtitle(
            subtitle: (isPhone ? task?.projectName : task.map { $0.modelSummary ?? $0.provider.name }) ?? "",
            showsStatus: isPhone
        ))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let task {
                if isPhone {
                    if let workspaceID = task.workspaceID {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Section(task.modelSummary ?? task.provider.name) {
                                    NavigationLink(value: Route.commands(workspaceID)) {
                                        Label("Commands", systemImage: "terminal")
                                    }
                                    NavigationLink(value: Route.sourceControl(workspaceID)) {
                                        Label("Source Control", systemImage: "arrow.triangle.branch")
                                    }
                                    Button("Scratch Pad", systemImage: "note.text") { showingScratchPad = true }
                                }
                            } label: {
                                Label("More", systemImage: "ellipsis")
                            }
                        }
                    }
                } else {
                    // iPad has room for the workspace links and scratch pad
                    // in place of the More menu.
                    if let workspaceID = task.workspaceID {
                        ToolbarItem(placement: .navigation) {
                            Button("Scratch Pad", systemImage: "note.text") { showingScratchPad = true }
                        }
                        ToolbarItemGroup(placement: .primaryAction) {
                            NavigationLink(value: Route.commands(workspaceID)) {
                                Label("Commands", systemImage: "terminal")
                            }
                            NavigationLink(value: Route.sourceControl(workspaceID)) {
                                Label("Source Control", systemImage: "arrow.triangle.branch")
                            }
                        }
                    }
                    if Self.showsInfoMenu {
                        if task.workspaceID != nil {
                            ToolbarSpacer(.fixed, placement: .primaryAction)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            TaskInfoMenu(
                                task: task,
                                taskToRename: $taskToRename,
                                taskToDelete: $taskToDelete,
                                showingDetails: $showingDetails
                            )
                        }
                    }
                }
            }
            // iPad has no bottom bar; its inline input bar carries these.
            if isPhone {
                ToolbarItem(placement: .bottomBar) {
                    ComposerAttachmentMenu()
                }
                ToolbarSpacer(.fixed, placement: .bottomBar)
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    // A running agent can be stopped from where dictation sits.
                    if let task, task.actions.contains(.interrupt) {
                        Button("Stop", systemImage: "stop.fill", role: .destructive) {
                            client.send(.interrupt(taskID: task.id))
                        }
                        .tint(.red)
                    } else {
                        ComposerDictationButton()
                    }
                }
            }
        }
        .taskComposer(composer, task: task, prompt: "Ask anything…", submit: sendDraft)
        .composerAttachmentPickers(composer)
        .environment(composer)
        .sheet(isPresented: $showingDetails) {
            if let task { TaskDetailsSheet(task: task) }
        }
        .sheet(isPresented: $showingScratchPad) {
            if let workspaceID = task?.workspaceID {
                ScratchPadSheet(workspaceID: workspaceID)
            }
        }
        .taskConfirmations(rename: $taskToRename, delete: $taskToDelete)
        // The screen outlives its task when another opens, so each task keeps
        // its own draft and images, waiting for it to open again.
        .onChange(of: taskID) { oldID, newID in
            client.setVisibleTask(newID)
            composer.isFocused = false
            if composer.hasContent {
                stashedComposers[oldID] = composer
            }
            composer = stashedComposers.removeValue(forKey: newID) ?? TaskComposer()
        }
        .task(id: taskID) {
            await client.follow(.transcript(taskID: taskID))
        }
        .task(id: task) {
            // Viewing a finished task reads it, as selecting it does on the host.
            if let task, task.hasUnreadResult {
                client.send(.task(id: task.id, action: .viewed))
            }
        }
    }

    private func sendDraft() -> Bool {
        guard let task else { return false }
        return composer.submit(to: task, using: client)
    }
}
