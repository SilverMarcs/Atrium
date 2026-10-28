import SwiftUI

/// One task's conversation, with a prompt field that sends to its agent on its host.
struct TaskDetailScreen: View {
    @Environment(DictationSettings.self) private var dictationSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HostDirectory.self) private var hosts
    let ref: TaskRef
    @State private var showingScratchPad = false
    @State private var composer = TaskComposer()
    /// Shared by every task the screen shows, so the composer's field
    /// geometry it tracks survives switching tasks.
    @State private var sendAnimator = PromptSendAnimator()
    /// Drafts left in other tasks, restored when their task opens again.
    @State private var stashedComposers: [TaskRef: TaskComposer] = [:]

    private var host: HostClient? { hosts.host(ref.hostID) }

    /// The task a draft has become, once the host creates it, so the screen
    /// carries on with it in place.
    private var resolvedRef: TaskRef { TaskRef(hostID: ref.hostID, taskID: host?.resolvedTaskID(ref.taskID) ?? ref.taskID) }

    private var hostTask: WireTask? { host?.task(resolvedRef.taskID) }

    /// The host's task, or what a draft shows until the host lists it.
    private var item: HostTask? { hosts.task(resolvedRef) }
    private var task: WireTask? { item?.task }
    private var workspace: WorkspaceRef? { task?.workspaceID.map { WorkspaceRef(hostID: ref.hostID, workspaceID: $0) } }

    /// A draft's model can't be changed until the host has created its task.
    private var models: [AgentModel] { hostTask.flatMap { task in host?.models(for: task.provider) } ?? [] }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        let targetComposer = composer
        let editing = composer.messageEdit
        Group {
            if let item {
                TaskChatView(item: item)
            } else if host?.tasks == nil || host?.isConnected != true {
                ProgressView()
                    .controlSize(.large)
            } else {
                ContentUnavailableView(
                    "Task Unavailable",
                    systemImage: "questionmark.bubble",
                    description: Text("It may still be starting, or it was deleted on its host.")
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
            hosts.setVisibleTask(resolvedRef)
            host?.onPendingPromptShown = { [sendAnimator] promptID, messageID in
                sendAnimator.confirm(promptID, as: messageID)
            }
        }
        .onDisappear {
            if hosts.visibleTask == resolvedRef { hosts.setVisibleTask(nil) }
            host?.onPendingPromptShown = nil
            composer.dictation.cancel()
            sendAnimator.cancelAll()
        }
        .navigationTitle(task?.title ?? "Task")
        .modifier(ConnectionStatusSubtitle(
            hosts: host.map { [$0] } ?? [],
            subtitle: subtitle,
            showsStatus: isPhone
        ))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let task {
                if isPhone, task.workspaceID != nil, let item {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Session", systemImage: "square.and.pencil") { hosts.openDraft(matching: item) }
                    }
                }
                if isPhone {
                    if task.workspaceID != nil || !models.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                if !models.isEmpty {
                                    Section {
                                        TaskModelMenu(provider: task.provider, selection: task.modelSelection, models: models) { action in
                                            host?.send(.task(id: task.id, action: action))
                                        }
                                    }
                                }
                                if let workspace {
                                    Section {
                                        ProjectLinks(workspace: workspace, root: projectPath)
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
                                perform: { action in host?.send(.task(id: task.id, action: action)) },
                                showsToolbarLabel: true
                            )
                            .labelStyle(.titleOnly)
                        }
                        if task.workspaceID != nil {
                            ToolbarSpacer(.fixed, placement: .primaryAction)
                        }
                    }
                    if let workspace {
                        ToolbarItem(placement: .navigation) {
                            Button("Scratch Pad", systemImage: "note.text") { showingScratchPad = true }
                        }
                        ToolbarItemGroup(placement: .primaryAction) {
                            ProjectLinks(workspace: workspace, root: projectPath)
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
                    if let item, item.task.actions.contains(.interrupt) {
                        Button("Stop", systemImage: "stop.fill", role: .destructive) {
                            item.host.interrupt(item.task.id)
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .taskComposer(composer, item: item, prompt: "Ask anything…", submit: sendDraft)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isPhone, let edit = composer.messageEdit {
                ConversationEditContent(edit: edit)
            }
        }
        .composerAttachmentPickers(composer)
        .modifier(ComposerDropHandler(isEnabled: item != nil && editing?.isSubmitting != true) { content in
            guard targetComposer.messageEdit === editing, editing?.isSubmitting != true else { return }
            switch content {
            case .text(let text):
                targetComposer.draft += text
            case .image(let image):
                try targetComposer.attachPastedImage(image)
            }
        })
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
        .sheet(isPresented: $showingScratchPad) {
            if let host, let workspaceID = task?.workspaceID {
                ScratchPadSheet(host: host, workspaceID: workspaceID)
            }
        }
        .modifier(AgentInteractionPresentation(
            requests: hostTask?.interactions ?? [],
            respond: { interaction, decision in
                _ = try await host?.request(.task(id: interaction.taskID, action: .respond(interactionID: interaction.id, decision: decision)))
            },
            canPresent: scenePhase == .active && !showingScratchPad
                && !composer.isPickingPhotos && !composer.isTakingPhoto
                && composer.dictation.error == nil,
            prepareToPresent: { composer.isFocused = false }
        ))
        // The screen outlives its task when another opens, so each task keeps
        // its own draft and images, waiting for it to open again. A new task
        // opened from the screen's draft carries on with the draft's.
        .onChange(of: resolvedRef) { oldRef, newRef in
            hosts.setVisibleTask(newRef)
            guard oldRef.hostID != newRef.hostID || host?.drafts[oldRef.taskID]?.taskID != newRef.taskID else { return }
            composer.dictation.cancel()
            sendAnimator.cancelAll()
            composer.isFocused = false
            // A draft that's left isn't opened again.
            if composer.hasContent, !TaskDraft.isDraftID(oldRef.taskID) {
                stashedComposers[oldRef] = composer
            }
            composer = stashedComposers.removeValue(forKey: newRef) ?? TaskComposer()
        }
        .task(id: resolvedRef) {
            // The host has no transcript for a draft.
            guard !TaskDraft.isDraftID(resolvedRef.taskID) else { return }
            await host?.follow(.transcript(taskID: resolvedRef.taskID))
        }
        .task(id: task) {
            // Viewing a finished task reads it, as selecting it does on the host.
            if let task, task.hasUnreadResult {
                host?.send(.task(id: task.id, action: .viewed))
            }
        }
    }

    private var projectPath: String {
        host?.workspace(task?.workspaceID)?.path ?? ""
    }

    private var subtitle: String {
        guard let task else { return "" }
        return hosts.showsHostNames || hosts.filter != nil && hosts.hosts.count > 1
            ? "\(task.projectName) · \(host?.name ?? "")" : task.projectName
    }

    private func sendDraft(from sourceFrame: CGRect?) -> Bool {
        guard let item else { return false }
        return composer.submit(to: item, animator: sendAnimator, from: sourceFrame)
    }
}
