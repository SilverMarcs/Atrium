import AtriumProtocol

/// The permission-mode menu's state for a task, a new chat or a mirrored companion task.
nonisolated struct TaskPermissionSelection: Equatable, Sendable {
    /// Nil while the agent runs in a mode Atrium doesn't offer, such as plan mode.
    var mode: PermissionMode?
    /// The modes the agent can use with its model, as its host allows.
    var available: [PermissionMode]
    /// The modes the chat switches to only by restarting.
    var needingRestart: [PermissionMode]
    var canSelect: Bool
}

extension WireTask {
    /// Nil when the host doesn't say which modes its agents can use.
    func permissionSelection(using models: [AgentModel]) -> TaskPermissionSelection? {
        guard let available = models.permissionModes(running: model) else { return nil }
        return TaskPermissionSelection(
            mode: permissionMode,
            available: available,
            needingRestart: permissionModesNeedingRestart ?? [],
            canSelect: actions.contains(.selectModel)
        )
    }
}
