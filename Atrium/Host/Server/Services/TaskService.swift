import Foundation

/// Performs task actions for clients through the controllers that own tasks,
/// so every client follows identical rules.
@MainActor
struct TaskService {
    let integrations: AgentIntegrationStore
    let sessions: TaskSessionController
    let workspaces: WorkspaceStore

    func perform(_ action: TaskAction, onTask id: String) async -> HostReply {
        guard let thread = integrations.threads.first(where: { $0.id == id }) else {
            return .failed(message: "This task no longer exists.")
        }
        return await reportingErrors {
            switch action {
            case .respond(let interactionID, let decision):
                guard let request = integrations.interactions.first(where: { $0.id == interactionID && $0.taskID == id }) else {
                    return .failed(message: "This request has already been answered or cancelled.")
                }
                do { try await integrations.respond(to: request, with: decision) }
                catch { return .failed(message: error.localizedDescription) }
            case .settle:
                sessions.settle(thread)
            case .restore:
                sessions.restore(thread)
            case .snooze(let date):
                sessions.snooze(thread, until: date)
            case .unsnooze:
                sessions.unsnooze(thread)
            case .viewed:
                integrations.acknowledgeResult(for: thread.id)
            case .markRead:
                await integrations.markRead(thread)
            case .markUnread:
                await integrations.markUnread(thread)
            case .rename(let title):
                await integrations.renameThread(thread, to: title)
            case .fork:
                if let fork = await sessions.fork(thread) { return .task(id: fork.id) }
            case .delete:
                await sessions.delete(thread)
            case .selectModel(let model, let reasoningEffort):
                return await changeSettings(.model(model, reasoningEffort: reasoningEffort), of: thread)
            case .setFastMode(let isOn):
                return await changeSettings(.fastMode(isOn), of: thread)
            }
            return .done
        }
    }

    func prompt(_ text: String, images: [Data], toTask id: String) async -> HostReply {
        guard let thread = integrations.threads.first(where: { $0.id == id }) else {
            return .failed(message: "This task no longer exists.")
        }
        do {
            let imageURLs = try PromptAttachments.save(images)
            try await sessions.sendPrompt(text, images: imageURLs, to: thread)
            // A successful prompt wakes the task even before its provider reports
            // the new turn, matching the client's optimistic move.
            sessions.restore(thread)
            sessions.unsnooze(thread)
            return .done
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async -> HostReply {
        do {
            try await sessions.changeSettings(change, of: thread)
            return .done
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    func interrupt(task id: String) async -> HostReply {
        guard let thread = integrations.threads.first(where: { $0.id == id }) else {
            return .failed(message: "This task no longer exists.")
        }
        do {
            try await sessions.interrupt(thread)
            return .done
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    func compose(provider: AgentProvider, workspaceID: UUID, settings: TaskStartSettings? = nil) async -> HostReply {
        guard integrations.enabledProviders.contains(provider) else {
            return .failed(message: "That agent isn’t enabled on this host.")
        }
        guard let workspace = workspaces.workspaces.first(where: { $0.id == workspaceID }) else {
            return .failed(message: "That project is no longer on this host.")
        }
        guard !sessions.isOpening else {
            return .failed(message: "This host is still opening another task.")
        }
        return await reportingErrors {
            guard let thread = await sessions.compose(provider: provider, workspace: workspace, settings: settings) else {
                return .failed(message: "Couldn’t start a task.")
            }
            return .task(id: thread.id)
        }
    }

    /// The controllers report failures as the integration store's action error.
    /// A failure is returned to the client that caused it instead.
    private func reportingErrors(_ operation: () async -> HostReply) async -> HostReply {
        let previous = integrations.actionError
        let reply = await operation()
        guard let error = integrations.actionError, error != previous else { return reply }
        integrations.actionError = previous
        return .failed(message: error)
    }
}
