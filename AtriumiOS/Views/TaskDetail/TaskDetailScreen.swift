import SwiftUI

/// One task's conversation, with a prompt field that sends to its agent on the host.
struct TaskDetailScreen: View {
    @Environment(DictationSettings.self) private var dictationSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CompanionClient.self) private var client
    let taskID: String
    @State private var showingScratchPad = false
    @State private var showingDetails = false
    @State private var taskToRename: WireTask?
    @State private var taskToDelete: WireTask?
    @State private var composer = TaskComposer()
    /// Shared by every task the screen shows, so the composer's field
    /// geometry it tracks survives switching tasks.
    @State private var sendAnimator = PromptSendAnimator()
    /// Drafts left in other tasks, restored when their task opens again.
    @State private var stashedComposers: [String: TaskComposer] = [:]

    /// The task's info menu is hidden for now; its actions stay wired up.
    private static let showsInfoMenu = false

    /// The task a draft has become, once the host creates it, so the screen
    /// carries on with it in place.
    private var resolvedTaskID: String { client.drafts[taskID]?.taskID ?? taskID }

    private var hostTask: WireTask? { client.task(resolvedTaskID) }

    /// The host's task, or what a draft shows until the host lists it.
    private var task: WireTask? { hostTask ?? client.draftTask(resolvedTaskID) }

    /// A draft's model can't be changed until the host has created its task.
    private var models: [AgentModel] { hostTask.map { client.models(for: $0.provider) } ?? [] }

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
        .onChange(of: dictationSettings.isEnabled) { _, enabled in
            if !enabled { composer.dictation.cancel() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { composer.dictation.cancel() }
        }
        .onAppear {
            client.setVisibleTask(resolvedTaskID)
            client.onPendingPromptShown = { [sendAnimator] promptID, messageID in
                sendAnimator.confirm(promptID, as: messageID)
            }
        }
        .onDisappear {
            client.clearVisibleTask(resolvedTaskID)
            client.onPendingPromptShown = nil
            composer.dictation.cancel()
            sendAnimator.cancelAll()
        }
        .navigationTitle(task?.title ?? "Task")
        .modifier(ConnectionStatusSubtitle(
            subtitle: task?.projectName ?? "",
            showsStatus: isPhone
        ))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let task {
                if isPhone {
                    if task.workspaceID != nil || !models.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                if !models.isEmpty {
                                    Section {
                                        TaskModelMenu(provider: task.provider, selection: task.modelSelection, models: models) { action in
                                            client.send(.task(id: task.id, action: action))
                                        }
                                    }
                                }
                                if let workspaceID = task.workspaceID {
                                    Section {
                                        NavigationLink(value: Route.commands(workspaceID)) {
                                            Label("Commands", systemImage: "terminal")
                                        }
                                        NavigationLink(value: Route.sourceControl(workspaceID)) {
                                            Label("Source Control", systemImage: "arrow.triangle.branch")
                                        }
                                        Button("Scratch Pad", systemImage: "note.text") { showingScratchPad = true }
                                    }
                                }
                            } label: {
                                Label("More", systemImage: "ellipsis")
                            }
                        }
                    }
                } else {
                    // iPad has room for the model picker, workspace links and
                    // scratch pad in place of the More menu.
                    if !models.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            TaskModelMenu(
                                provider: task.provider,
                                selection: task.modelSelection,
                                models: models,
                                perform: { action in client.send(.task(id: task.id, action: action)) },
                                showsToolbarLabel: true
                            )
                            .labelStyle(.titleOnly)
                        }
                        if task.workspaceID != nil {
                            ToolbarSpacer(.fixed, placement: .primaryAction)
                        }
                    }
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
                ToolbarItem(placement: .bottomBar) {
                    ComposerDictationButton()
                }
                if dictationSettings.isEnabled, task?.actions.contains(.interrupt) == true {
                    ToolbarSpacer(.fixed, placement: .bottomBar)
                }
                ToolbarItem(placement: .bottomBar) {
                    if let task, task.actions.contains(.interrupt) {
                        Button("Stop", systemImage: "stop.fill", role: .destructive) {
                            client.send(.interrupt(taskID: task.id))
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .taskComposer(composer, task: task, prompt: "Ask anything…", submit: sendDraft)
        .composerAttachmentPickers(composer)
        .alert("Couldn’t Dictate", isPresented: Binding(
            get: { composer.dictation.error != nil },
            set: { if !$0 { composer.dictation.error = nil } }
        )) {
            Button("OK") { composer.dictation.error = nil }
        } message: {
            Text(composer.dictation.error ?? "")
        }
        .environment(composer)
        .environment(sendAnimator)
        .sheet(isPresented: $showingDetails) {
            if let task { TaskDetailsSheet(task: task) }
        }
        .sheet(isPresented: $showingScratchPad) {
            if let workspaceID = task?.workspaceID {
                ScratchPadSheet(workspaceID: workspaceID)
            }
        }
        .taskConfirmations(rename: $taskToRename, delete: $taskToDelete)
        .modifier(AgentInteractionPresentation(
            requests: hostTask?.interactions ?? [],
            respond: { interaction, decision in
                _ = try await client.request(.task(id: interaction.taskID, action: .respond(interactionID: interaction.id, decision: decision)))
            },
            canPresent: scenePhase == .active && !showingDetails && !showingScratchPad
                && taskToRename == nil && taskToDelete == nil
                && !composer.isPickingPhotos && !composer.isTakingPhoto
                && composer.dictation.error == nil,
            prepareToPresent: { composer.isFocused = false }
        ))
        // The screen outlives its task when another opens, so each task keeps
        // its own draft and images, waiting for it to open again. A new task
        // opened from the screen's draft carries on with the draft's.
        .onChange(of: resolvedTaskID) { oldID, newID in
            client.setVisibleTask(newID)
            guard client.drafts[oldID]?.taskID != newID else { return }
            composer.dictation.cancel()
            sendAnimator.cancelAll()
            composer.isFocused = false
            // A draft that's left isn't opened again.
            if composer.hasContent, !TaskDraft.isDraftID(oldID) {
                stashedComposers[oldID] = composer
            }
            composer = stashedComposers.removeValue(forKey: newID) ?? TaskComposer()
        }
        .task(id: resolvedTaskID) {
            // The host has no transcript for a draft.
            guard !TaskDraft.isDraftID(resolvedTaskID) else { return }
            await client.follow(.transcript(taskID: resolvedTaskID))
        }
        .task(id: task) {
            // Viewing a finished task reads it, as selecting it does on the host.
            if let task, task.hasUnreadResult {
                client.send(.task(id: task.id, action: .viewed))
            }
        }
    }

    private func sendDraft(from sourceFrame: CGRect?) -> Bool {
        guard let task else { return false }
        return composer.submit(to: task, using: client, animator: sendAnimator, from: sourceFrame)
    }
}
