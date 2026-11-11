import AtriumClient
import AtriumProtocol
import Foundation

/// Where this device starts new tasks: on the host, in the project and with
/// the agent it last started one with.
extension HostClient {
    private static let newTaskProviderKey = "newTaskProvider"
    private static let newTaskWorkspacesKey = "newTaskWorkspaces"
    static let newTaskHostKey = "newTaskHost"

    /// The agent a new task starts with: the one this device last started a
    /// task with, while the host has it enabled, else the host's first.
    var defaultProvider: AgentProvider? {
        let last = UserDefaults.standard.string(forKey: Self.newTaskProviderKey).flatMap(AgentProvider.init(rawValue:))
        return enabledProviders.first { $0 == last } ?? enabledProviders.first
    }

    /// The project a new task starts in: the one this device last started a
    /// task in on this host, while the host still has it, else its first.
    var defaultWorkspaceID: UUID? {
        let workspaces = tasks?.workspaces ?? []
        let last = (UserDefaults.standard.dictionary(forKey: Self.newTaskWorkspacesKey)?[id] as? String).flatMap(UUID.init(uuidString:))
        return workspaces.first { $0.id == last }?.id ?? workspaces.first?.id
    }

    /// Whether a new task can start here, with an agent and a project to start it in.
    var canStartTask: Bool {
        isConnected && defaultProvider != nil && defaultWorkspaceID != nil
    }

    /// The next new chat starts where this one did.
    func rememberNewTask(_ draft: TaskDraft) {
        var workspaces = UserDefaults.standard.dictionary(forKey: Self.newTaskWorkspacesKey) ?? [:]
        workspaces[id] = draft.workspaceID.uuidString
        UserDefaults.standard.set(workspaces, forKey: Self.newTaskWorkspacesKey)
        UserDefaults.standard.set(id, forKey: Self.newTaskHostKey)
        UserDefaults.standard.set(draft.provider.rawValue, forKey: Self.newTaskProviderKey)
    }

    func deletionMessage(for task: WireTask) -> String {
        tasks?.providers.first { $0.provider == task.provider }?.deletionMessage
            ?? "This permanently deletes the task and its agent history on \(name). This cannot be undone."
    }
}
