import SwiftUI

/// One task's conversation, with a prompt field that sends to its agent on its host.
struct TaskDetailScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HostDirectory.self) private var hosts
    @Environment(\.replaceSideChat) private var replaceSideChat
    @Environment(\.isPresented) private var isPresented
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let ref: TaskRef
    /// Shared by every task the screen shows, so the composer's field
    /// geometry it tracks survives switching tasks.
    @State private var sendAnimator = PromptFlights()
    @AppStorage(SendMode.key) private var sendMode = SendMode.steer

    private var host: HostClient? { hosts.host(ref.hostID) }

    /// The task a draft has become, once the host creates it, so the screen
    /// carries on with it in place.
    private var resolvedRef: TaskRef { TaskRef(hostID: ref.hostID, taskID: host?.resolvedTaskID(ref.taskID) ?? ref.taskID) }

    /// Each task keeps its own draft and images while others are shown.
    private var composer: TaskComposer { hosts.composer(for: resolvedRef) }

    /// The host's task, or what a draft shows until the host lists it.
    private var item: HostTask? { hosts.task(resolvedRef) }
    private var task: WireTask? { item?.task }

    private var composerPrompt: String {
        guard let item, !TaskDraft.isDraftID(item.task.id) else { return "Ask anything…" }
        let task = item.task
        let hasConversation = item.host.conversations.transcripts[task.id]?.isEmpty == false
            || item.host.conversations.pendingPrompts[task.id]?.isEmpty == false
            || task.queuedPrompt != nil
        return hasConversation ? "Ask \(task.provider.name)" : "Ask anything…"
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var newChatPlacement: ToolbarItemPlacement { isPhone ? .primaryAction : .navigation }

    /// Whether the screen is in view. A collapsed split view, as on iPhone,
    /// keeps the detail column's screen while the task list shows, and stops
    /// presenting it as soon as going back starts, before it disappears, so a
    /// new chat created meanwhile doesn't open over the list.
    private var isOnScreen: Bool { horizontalSizeClass != .compact || isPresented }

    var body: some View {
        let composer = composer
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
        .onAppear {
            if isOnScreen { hosts.setVisibleTask(resolvedRef) }
            host?.onPendingPromptShown = { [sendAnimator] promptID, messageID in
                sendAnimator.confirm(promptID, as: messageID)
            }
        }
        .onDisappear {
            if hosts.visibleTask == resolvedRef { hosts.setVisibleTask(nil) }
            host?.onPendingPromptShown = nil
            sendAnimator.cancelAll()
            hosts.releaseComposer(for: resolvedRef)
        }
        .onChange(of: isOnScreen) { _, isOnScreen in
            if isOnScreen {
                hosts.setVisibleTask(resolvedRef)
            } else if hosts.visibleTask == resolvedRef {
                hosts.setVisibleTask(nil)
            }
        }
        .navigationTitle(title)
        .modifier(ConnectionStatusSubtitle(
            hosts: host.map { [$0] } ?? [],
            subtitle: subtitle,
            showsStatus: isPhone
        ))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let task {
                // On iPhone the new-chat button sits just left of the More menu;
                // iPad keeps it at the leading edge.
                if task.isSideChat, let item {
                    ToolbarItem(placement: newChatPlacement) {
                        NewSideChatButton(sideChat: item, open: replaceSideChat)
                    }
                } else if task.workspaceID != nil, let item {
                    ToolbarItem(placement: newChatPlacement) {
                        Button("New Session", systemImage: "square.and.pencil") { hosts.openNewChat() }
                    }
                }
                if let item, !task.isSideChat, task.workspaceID != nil || item.hasSubagents
                    || item.sideChat != nil || task.actions.contains(.sideChat) || !task.pullRequests.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        TaskMoreMenu(item: item)
                    }
                }
            }
        }
        // A subagent answers only to its own agent, so it has no composer.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if item?.task.isSubagent != true {
                ComposerBar(item: item, prompt: composerPrompt, submit: sendDraft) {
                    if let item, let draft = item.host.newChatDraft(item.task.id) {
                        NewChatPicker(hosts: hosts, host: item.host, draft: draft)
                    }
                }
            }
        }
        .composerAttachmentPickers(composer)
        .replySelectionActions(composer, item: item)
        .composerDropHandler(composer, isEnabled: item?.task.actions.contains(.attachImages) == true)
        .composerDictationLifecycle(composer)
        .environment(composer)
        .environment(sendAnimator)
        .sheet(isPresented: Bindable(composer).isShowingScratchpad) {
            if let item {
                ScratchpadSheet(item: item, composer: composer)
            }
        }
        .modifier(AgentInteractionPresentation(
            requests: item?.pendingRequests ?? [],
            respond: { interaction, decision in
                _ = try await host?.request(.task(id: interaction.taskID, action: .respond(interactionID: interaction.id, decision: decision)))
            },
            canPresent: scenePhase == .active && !composer.isShowingScratchpad
                && !composer.isPickingPhotos && !composer.isTakingPhoto
                && composer.dictation.error == nil,
            prepareToPresent: { composer.isFocused = false }
        ))
        // The screen outlives its task when another opens, so the task it
        // leaves keeps its draft for when it opens again. A new task opened
        // from the screen's draft carries on with the draft's composer.
        .onChange(of: resolvedRef) { oldRef, newRef in
            // Only a screen in view shows its new task; one kept behind the
            // task list leaves it to be shown when it's opened.
            if hosts.visibleTask == oldRef { hosts.setVisibleTask(newRef) }
            guard oldRef.hostID != newRef.hostID || host?.drafts[oldRef.taskID]?.taskID != newRef.taskID else { return }
            // A recording carries on, to finish when its task opens again.
            hosts.composer(for: oldRef).isFocused = false
            sendAnimator.cancelAll()
            hosts.releaseComposer(for: oldRef)
        }
        .task(id: resolvedRef) {
            // The host has no transcript for a draft.
            guard !TaskDraft.isDraftID(resolvedRef.taskID) else { return }
            await host?.follow(.transcript(taskID: resolvedRef.taskID))
        }
        .followsProjectScope(of: item)
        .task(id: isOnScreen ? task : nil) {
            // Viewing a finished task reads it, as selecting it does on the host.
            if isOnScreen, let task, task.hasUnreadResult {
                host?.send(.task(id: task.id, action: .viewed))
            }
        }
    }

    private var title: String { item.map(hosts.navigationTitle) ?? "Task" }
    private var subtitle: String { item.map(hosts.navigationSubtitle) ?? "" }

    private func sendDraft(from sourceFrame: CGRect?) -> Bool {
        guard let item else { return false }
        return composer.submit(to: item, animator: sendAnimator, from: sourceFrame, mode: sendMode)
    }
}
