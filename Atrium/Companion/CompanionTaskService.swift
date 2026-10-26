import Foundation

/// Performs task actions requested by the companion through the same
/// controllers the sidebar uses, so both apps follow identical rules.
@MainActor
struct CompanionTaskService {
    let integrations: AgentIntegrationStore
    let sessions: TaskSessionController
    let workspaces: WorkspaceStore

    func perform(_ action: CompanionTaskAction, onTask id: String) async -> CompanionReply {
        guard let thread = integrations.threads.first(where: { $0.id == id }) else {
            return .failed(message: "This task no longer exists.")
        }
        return await reportingErrors {
            switch action {
            case .settle:
                sessions.settle(thread)
            case .restore:
                sessions.restore(thread)
            case .snooze(let date):
                sessions.snooze(thread, until: date)
            case .unsnooze:
                sessions.unsnooze(thread)
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
            }
            return .done
        }
    }

    func prompt(_ text: String, toTask id: String) async -> CompanionReply {
        guard let thread = integrations.threads.first(where: { $0.id == id }) else {
            return .failed(message: "This task no longer exists.")
        }
        do {
            try await sessions.sendPrompt(text, to: thread)
            return .done
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    func interrupt(task id: String) async -> CompanionReply {
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

    func compose(provider: AgentProvider, workspaceID: UUID) async -> CompanionReply {
        guard integrations.enabledProviders.contains(provider) else {
            return .failed(message: "That agent isn’t enabled on your Mac.")
        }
        guard let workspace = workspaces.workspaces.first(where: { $0.id == workspaceID }) else {
            return .failed(message: "That project is no longer on your Mac.")
        }
        guard !sessions.isOpening else {
            return .failed(message: "Your Mac is still opening another task.")
        }
        return await reportingErrors {
            guard let thread = await sessions.compose(provider: provider, workspace: workspace) else {
                return .failed(message: "Couldn’t start a task.")
            }
            return .task(id: thread.id)
        }
    }

    /// The controllers report failures through the sidebar's alert. A failure caused
    /// by the companion is returned to it instead of interrupting the Mac.
    private func reportingErrors(_ operation: () async -> CompanionReply) async -> CompanionReply {
        let previous = integrations.actionError
        let reply = await operation()
        guard let error = integrations.actionError, error != previous else { return reply }
        integrations.actionError = previous
        return .failed(message: error)
    }
}
