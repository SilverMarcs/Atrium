import Foundation

extension HostClient {
    // MARK: - Prompts

    func skills(for task: WireTask) async throws -> [AgentSkill] {
        guard case .skills(let skills) = try await request(.skills(taskID: task.id, provider: task.provider, workspaceID: task.workspaceID)) else {
            throw HostClientError.unexpectedReply
        }
        let names = Set(skills.map(\.name))
        if skillNames[task.id] != names { skillNames[task.id] = names }
        return skills
    }

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

    /// Has a prompt wait for the agent's current turn to end, added to any
    /// prompt already waiting. The task shows it waiting at once.
    func queuePrompt(_ text: String, images: [Data] = [], to taskID: String) async throws {
        let id = task(taskID)?.queuedPrompt?.id ?? UUID()
        _ = try await request(.prompt(taskID: taskID, text: text, images: images, queue: id))
    }

    /// Takes back the prompt waiting for the agent's turn to end, to edit it.
    /// - Returns: Its text and images as they were sent.
    func takeQueuedPrompt(from taskID: String) async throws -> (text: String, images: [Data]) {
        guard case .queuedPrompt(let text, let images) = try await request(.task(id: taskID, action: .takeQueuedPrompt)) else {
            throw HostClientError.unexpectedReply
        }
        return (text, images)
    }

    /// Takes a draft out of a project's scratchpad, to put in a composer.
    /// - Returns: Its text and images as they were added.
    func takeScratchpadDraft(_ id: UUID, from workspaceID: UUID) async throws -> (text: String, images: [Data]) {
        guard case .queuedPrompt(let text, let images) = try await request(
            .workspace(id: workspaceID, action: .removeScratchpadDraft(id: id))
        ) else { throw HostClientError.unexpectedReply }
        return (text, images)
    }

    /// Stops the agent's turn.
    /// - Returns: The prompt that was queued behind the turn, for the
    ///   composer, with its images as they were sent.
    func interrupt(_ taskID: String) async throws -> (text: String, images: [Data])? {
        guard case .queuedPrompt(let text, let images) = try await request(.interrupt(taskID: taskID)) else { return nil }
        return (text, images)
    }

    /// Sends a prompt to a task's agent and returns once the host has handed it
    /// over. Sending again with the same key, after the reply was lost,
    /// returns the first result instead of prompting the agent again.
    func submitPrompt(_ text: String, images: [Data] = [], to taskID: String, key: UUID) async throws {
        _ = try await request(.prompt(taskID: taskID, text: text, images: images), key: key)
    }

    /// Has the host create a task in one of its projects, ready for its first
    /// prompt. Asking again with the same key returns the same task.
    func createTask(
        provider: AgentProvider, workspaceID: UUID, settings: TaskStartSettings? = nil, key: UUID
    ) async throws -> String {
        guard case .task(let taskID) = try await request(
            .compose(provider: provider, workspaceID: workspaceID, settings: settings), key: key
        ) else {
            throw HostClientError.unexpectedReply
        }
        return taskID
    }

    /// Removes a prompt and the conversation after it, keeping files as they
    /// are, so an edited prompt can replace it.
    /// - Returns: The removed prompt's images, to send with its replacement.
    func rewind(_ taskID: String, before messageTarget: String) async throws -> [Data] {
        guard case .rewound(let messages, let images) = try await request(
            .task(id: taskID, action: .rewind(messageID: messageTarget))
        ) else { throw HostClientError.unexpectedReply }
        conversations.transcripts[taskID] = messages
        conversations.reconcile(taskID: taskID)
        return images
    }

    func deliver(_ id: UUID, to taskID: String) {
        guard conversations.pendingPrompts[taskID]?.contains(where: { $0.id == id }) == true else { return }
        conversations.tasksAwaitingAgent[taskID] = id
        // A draft's prompts wait for the host to create its task.
        if let draft = drafts[taskID] {
            if !draft.isCreating, draft.taskID == nil { createTask(from: draft) }
            return
        }
        conversations.deliver(id, to: taskID) { prompt in
            try await self.submitPrompt(prompt.text, images: prompt.images, to: taskID, key: prompt.id)
        } status: { [weak self] in
            self?.task(taskID)?.status
        }
    }
}
