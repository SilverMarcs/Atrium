import AtriumProtocol
import Foundation

extension HostClient {
    /// Opens a new task in a project. The host creates it once its first
    /// prompt is sent, so leaving it unsent leaves nothing behind.
    /// - Returns: The draft's ID.
    public func openDraft(in workspaceID: UUID, provider: AgentProvider, settings: TaskStartSettings? = nil) -> String {
        let draft = TaskDraft(workspaceID: workspaceID, provider: provider, settings: settings)
        drafts[draft.id] = draft
        // A new task has no messages to load.
        conversations.transcripts[draft.id] = []
        return draft.id
    }

    /// A draft whose first prompt hasn't been sent, which can still change.
    public func unsentDraft(_ id: String) -> TaskDraft? {
        drafts[id].flatMap { !$0.isCreating && $0.taskID == nil ? $0 : nil }
    }

    /// Changes a draft's project, agent or settings until its first prompt is sent.
    public func updateDraft(_ id: String, _ update: (inout TaskDraft) -> Void) {
        guard var draft = unsentDraft(id) else { return }
        update(&draft)
        drafts[id] = draft
    }

    /// Picks the agent a draft's task is created with, until its first prompt is sent.
    public func setProvider(_ provider: AgentProvider, ofDraft id: String) {
        updateDraft(id) { draft in
            guard draft.provider != provider else { return }
            draft.provider = provider
            draft.settings = nil
        }
    }

    /// Forgets a draft another has opened in place of, unless its first
    /// prompt has been sent, which leaves nothing behind on the host.
    public func closeDraft(_ id: String) {
        guard unsentDraft(id) != nil else { return }
        drafts[id] = nil
        conversations.remove(id)
    }

    /// The task a draft has become, once the host created it.
    public func resolvedTaskID(_ id: String) -> String {
        drafts[id]?.taskID ?? id
    }

    /// What a draft shows in place of its task, by the draft's ID or, once
    /// the host has created the task, by the task's own until the task list
    /// shows it.
    public func draftTask(_ id: String) -> WireTask? {
        guard let draft = drafts[id] ?? drafts.values.first(where: { $0.taskID == id }) else { return nil }
        let workspace = workspace(draft.workspaceID)
        let defaults = tasks?.providers.first { $0.provider == draft.provider }?.defaultSettings
        let model = draft.settings?.model ?? defaults?.model
        let reasoningEffort = draft.settings?.reasoningEffort ?? (draft.settings?.model == nil ? defaults?.reasoningEffort : nil)
        let supportsFastMode = models(for: draft.provider).model(running: model)?.supportsFastMode == true
        var actions: TaskActions = [.prompt, .attachImages]
        if !draft.isCreating, draft.taskID == nil, enabledProviders.contains(draft.provider), !models(for: draft.provider).isEmpty {
            actions.insert(.selectModel)
        }
        return WireTask(
            id: draft.taskID ?? draft.id,
            title: "New Task",
            provider: draft.provider,
            status: .idle,
            projectName: workspace?.name ?? "",
            path: workspace?.path ?? "",
            directory: workspace?.directory ?? "",
            workspaceID: draft.workspaceID,
            updatedAt: draft.createdAt,
            hasUnreadResult: false,
            isSettled: false,
            supportsDeletion: false,
            actions: actions,
            model: model,
            reasoningEffort: reasoningEffort,
            isFastMode: supportsFastMode && (draft.settings?.isFastMode ?? defaults?.isFastMode ?? false)
        )
    }

    /// Draft model choices belong only to this device until the first prompt.
    /// Never send a draft ID to the host as though it were an existing task.
    func performDraftRequest(_ request: HostRequest) -> HostReply? {
        guard case .task(let id, let action) = request, TaskDraft.isDraftID(id) else { return nil }
        guard let draft = unsentDraft(id), draftTask(id)?.actions.contains(.selectModel) == true else {
            return .failed(message: "This new chat can’t be changed right now.")
        }
        switch action {
        case .selectModel(let id, let reasoningEffort):
            guard let model = models(for: draft.provider).first(where: { $0.id == id }),
                  reasoningEffort.map({ model.reasoningEfforts.contains($0) }) ?? true else {
                return .failed(message: "That model or reasoning effort is no longer available.")
            }
            updateDraft(draft.id) {
                $0.settings = TaskStartSettings(
                    model: model.id, reasoningEffort: reasoningEffort,
                    isFastMode: model.supportsFastMode ? $0.settings?.isFastMode : false
                )
            }
        case .setFastMode(let isOn):
            guard !isOn || models(for: draft.provider).model(running: draftTask(id)?.model)?.supportsFastMode == true else {
                return .failed(message: "Fast mode isn’t available with this model.")
            }
            updateDraft(id) {
                var settings = $0.settings ?? TaskStartSettings()
                settings.isFastMode = isOn
                $0.settings = settings
            }
        default:
            return .failed(message: "This action needs an existing chat.")
        }
        return .done
    }

    /// The host's task, or what a draft shows until the host lists it.
    public func displayedTask(_ id: String) -> WireTask? {
        let id = resolvedTaskID(id)
        return task(id) ?? draftTask(id)
    }

    /// Has the host create a draft's task for its first prompt. Prompts sent
    /// meanwhile wait with it, and all fail together if the host can't.
    func createTask(from draft: TaskDraft) {
        var creating = draft
        creating.isCreating = true
        drafts[creating.id] = creating
        Task {
            do {
                let taskID = try await createTask(
                    provider: draft.provider, workspaceID: draft.workspaceID, settings: draft.settings, key: draft.key
                )
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
        if conversations.transcripts[taskID] == nil { conversations.transcripts[taskID] = [] }
        let prompts = conversations.pendingPrompts.removeValue(forKey: draftID) ?? []
        conversations.pendingPrompts[taskID, default: []].append(contentsOf: prompts)
        conversations.tasksAwaitingAgent[draftID] = nil
        for prompt in prompts where prompt.state == .sending {
            deliver(prompt.id, to: taskID)
        }
        connections?.delegate?.host(self, didCreateTask: taskID, from: draft)
    }

    /// Drops drafts whose task the task list now shows, once they're off screen.
    func dropListedDrafts() {
        for (id, draft) in drafts {
            guard let taskID = draft.taskID, task(taskID) != nil,
                  connections?.delegate?.host(self, isShowingDraft: id) != true else { continue }
            drafts[id] = nil
            conversations.transcripts[id] = nil
        }
    }
}
