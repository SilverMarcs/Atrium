import Foundation

extension HostClient {
    // MARK: - Prompts

    /// Sends a prompt to a task's agent, showing it in the timeline at once.
    /// A failed send stays there with a retry button instead of an alert.
    /// - Returns: The ID of the prompt's row in the timeline.
    @discardableResult
    func sendPrompt(_ text: String, images: [Data] = [], to taskID: String) -> PendingPrompt.ID {
        let status = task(taskID)?.status
        let prompt = conversations.enqueue(text, images: images, to: taskID, isSteer: status == .processing || status == .waiting)
        deliver(prompt.id, to: taskID)
        return prompt.id
    }

    func retryPrompt(_ id: UUID, in taskID: String) {
        conversations.prepareRetry(id, in: taskID)
        deliver(id, to: taskID)
    }

    func interrupt(_ taskID: String) {
        send(.interrupt(taskID: taskID))
    }

    private func deliver(_ id: UUID, to taskID: String) {
        guard conversations.pendingPrompts[taskID]?.contains(where: { $0.id == id }) == true else { return }
        conversations.tasksAwaitingAgent[taskID] = id
        // A draft's prompts wait for the host to create its task.
        if let draft = drafts[taskID] {
            if !draft.isCreating, draft.taskID == nil { createTask(from: draft) }
            return
        }
        conversations.deliver(id, to: taskID, using: self) { [weak self] in
            self?.task(taskID)?.status
        }
    }

    // MARK: - Drafts

    /// The agent a new task starts with: the one this device last started a
    /// task with, while the host has it enabled, else the host's first.
    var defaultProvider: AgentProvider? {
        let enabled = tasks?.providers.filter(\.isEnabled).map(\.provider) ?? []
        let last = UserDefaults.standard.string(forKey: "newTaskProvider").flatMap(AgentProvider.init(rawValue:))
        return enabled.first { $0 == last } ?? enabled.first
    }

    /// Opens a new task in a project; see `HostDirectory.openDraft(in:)`.
    /// - Returns: The draft's ID, or nil while the host has no agent enabled.
    func openDraft(in workspaceID: UUID, provider: AgentProvider? = nil, settings: TaskStartSettings? = nil) -> String? {
        guard let provider = provider ?? defaultProvider else { return nil }
        let draft = TaskDraft(workspaceID: workspaceID, provider: provider, settings: settings)
        drafts[draft.id] = draft
        // A new task has no messages to load.
        conversations.transcripts[draft.id] = []
        return draft.id
    }

    /// Picks the agent a draft's task is created with, until its first prompt is sent.
    func setProvider(_ provider: AgentProvider, ofDraft id: String) {
        guard var draft = drafts[id], !draft.isCreating, draft.taskID == nil, draft.provider != provider else { return }
        draft.provider = provider
        draft.settings = nil
        drafts[draft.id] = draft
    }

    /// Forgets a draft another task has opened in place of, unless its first
    /// prompt has been sent, which leaves nothing behind on the host.
    func closeDraft(_ id: String) {
        guard let draft = drafts[id], !draft.isCreating, draft.taskID == nil else { return }
        drafts[id] = nil
        conversations.remove(id)
    }

    /// The task a draft has become, once the host created it.
    func resolvedTaskID(_ id: String) -> String {
        drafts[id]?.taskID ?? id
    }

    /// What a draft shows in place of its task, by the draft's ID or, once
    /// the host has created the task, by the task's own until the task list
    /// shows it.
    func draftTask(_ id: String) -> WireTask? {
        guard let draft = drafts[id] ?? drafts.values.first(where: { $0.taskID == id }) else { return nil }
        let workspace = workspace(draft.workspaceID)
        return WireTask(
            id: draft.taskID ?? draft.id,
            title: "New Task",
            provider: draft.provider,
            status: .idle,
            projectName: workspace?.name ?? "",
            directory: workspace?.directory ?? "",
            workspaceID: draft.workspaceID,
            updatedAt: draft.createdAt,
            hasUnreadResult: false,
            isSettled: false,
            supportsDeletion: false,
            actions: .prompt,
            model: draft.settings?.model,
            reasoningEffort: draft.settings?.reasoningEffort,
            isFastMode: draft.settings?.isFastMode
        )
    }

    /// The host's task, or what a draft shows until the host lists it.
    func displayedTask(_ id: String) -> WireTask? {
        let id = resolvedTaskID(id)
        return task(id) ?? draftTask(id)
    }

    /// Has the host create a draft's task for its first prompt. Prompts sent
    /// meanwhile wait with it, and all fail together if the host can't.
    private func createTask(from draft: TaskDraft) {
        var creating = draft
        creating.isCreating = true
        drafts[creating.id] = creating
        Task {
            do {
                guard case .task(let taskID) = try await request(.compose(
                    provider: draft.provider, workspaceID: draft.workspaceID, settings: draft.settings
                )) else {
                    throw HostClientError.unexpectedReply
                }
                didCreateTask(taskID, from: draft.id)
            } catch {
                guard var failed = drafts[draft.id] else { return }
                failed.isCreating = false
                drafts[failed.id] = failed
                // The host's reason, such as the agent having been turned off,
                // says what to change before retrying.
                if case HostClientError.rejected(let message) = error { actionError = message }
                for prompt in conversations.pendingPrompts[draft.id] ?? [] where prompt.state == .sending {
                    conversations.markFailed(prompt.id, in: draft.id)
                }
                conversations.tasksAwaitingAgent[draft.id] = nil
            }
        }
    }

    /// Moves a draft's prompts to the task the host created for it and
    /// delivers them; screens showing the draft carry on with the task.
    private func didCreateTask(_ taskID: String, from draftID: String) {
        guard var draft = drafts[draftID] else { return }
        draft.isCreating = false
        draft.taskID = taskID
        drafts[draft.id] = draft
        UserDefaults.standard.set(draft.provider.rawValue, forKey: "newTaskProvider")
        if conversations.transcripts[taskID] == nil { conversations.transcripts[taskID] = [] }
        let prompts = conversations.pendingPrompts.removeValue(forKey: draftID) ?? []
        conversations.pendingPrompts[taskID, default: []].append(contentsOf: prompts)
        conversations.tasksAwaitingAgent[draftID] = nil
        for prompt in prompts where prompt.state == .sending {
            deliver(prompt.id, to: taskID)
        }
        // A draft on screen carries on as its task.
        if directory?.isShowing(TaskRef(hostID: id, taskID: draftID)) == true {
            directory?.open(TaskRef(hostID: id, taskID: taskID))
        }
    }

    /// Drops drafts whose task the task list now shows, once they're off screen.
    func dropListedDrafts() {
        for (id, draft) in drafts {
            guard let taskID = draft.taskID, task(taskID) != nil,
                  directory?.isShowing(TaskRef(hostID: self.id, taskID: id)) != true else { continue }
            drafts[id] = nil
            conversations.transcripts[id] = nil
        }
    }

    // MARK: - Task actions

    /// Performs a task menu action that needs no confirmation. Rename and
    /// delete need confirmation first, so screens handle those; a fork opens
    /// once it's created.
    func perform(_ action: TaskMenuAction, on task: WireTask) {
        let request: TaskAction
        switch action {
        case .settle: request = .settle
        case .restore: request = .restore
        case .snooze:
            guard let date = Calendar.current.date(byAdding: .day, value: 1, to: .now) else { return }
            request = .snooze(until: date)
        case .unsnooze: request = .unsnooze
        case .markRead: request = .markRead
        case .markUnread: request = .markUnread
        case .fork:
            Task {
                if case .task(let id) = await perform(.task(id: task.id, action: .fork)) {
                    directory?.open(TaskRef(hostID: self.id, taskID: id))
                }
            }
            return
        case .rename, .delete:
            return
        }
        send(.task(id: task.id, action: request))
    }

    func deletionMessage(for task: WireTask) -> String {
        tasks?.providers.first { $0.provider == task.provider }?.deletionMessage
            ?? "This permanently deletes the task and its agent history on \(name). This cannot be undone."
    }
}

extension HostClient: ConversationTransport {
    func deliverPrompt(_ prompt: PendingPrompt, to taskID: String) async throws {
        _ = try await request(.prompt(taskID: taskID, text: prompt.text, images: prompt.images))
    }

    func interruptConversation(taskID: String) async throws {
        _ = try await request(.interrupt(taskID: taskID))
    }
}
