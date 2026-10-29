import AtriumProtocol
import Foundation

extension HostClient {
    // MARK: - Prompts

    /// Sends a prompt to a task's agent, showing it in the timeline at once.
    /// A failed send stays there with a retry button instead of an alert.
    /// - Returns: The ID of the prompt's row in the timeline.
    @discardableResult
    public func sendPrompt(_ text: String, images: [Data] = [], to taskID: String) -> PendingPrompt.ID {
        let status = task(taskID)?.status
        let prompt = conversations.enqueue(text, images: images, to: taskID, isSteer: status == .processing || status == .waiting)
        deliver(prompt.id, to: taskID)
        return prompt.id
    }

    /// Sends a failed prompt again. It keeps its key, so if the host did get
    /// it the first time, the agent doesn't get it twice.
    public func retryPrompt(_ id: UUID, in taskID: String) {
        conversations.prepareRetry(id, in: taskID)
        deliver(id, to: taskID)
    }

    public func interrupt(_ taskID: String) {
        send(.interrupt(taskID: taskID))
    }

    /// Sends a prompt to a task's agent and returns once the host has handed it
    /// over. Sending again with the same key, after the reply was lost,
    /// returns the first result instead of prompting the agent again.
    public func submitPrompt(_ text: String, images: [Data] = [], to taskID: String, key: UUID) async throws {
        _ = try await request(.prompt(taskID: taskID, text: text, images: images), key: key)
    }

    /// Has the host create a task in one of its projects, ready for its first
    /// prompt. Asking again with the same key returns the same task.
    public func createTask(
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
    public func rewind(_ taskID: String, before messageTarget: String) async throws -> [Data] {
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
        conversations.deliver(id, to: taskID, using: self) { [weak self] in
            self?.task(taskID)?.status
        }
    }
}

extension HostClient: ConversationTransport {
    func deliverPrompt(_ prompt: PendingPrompt, to taskID: String) async throws {
        try await submitPrompt(prompt.text, images: prompt.images, to: taskID, key: prompt.id)
    }

    func interruptConversation(taskID: String) async throws {
        _ = try await request(.interrupt(taskID: taskID))
    }
}
