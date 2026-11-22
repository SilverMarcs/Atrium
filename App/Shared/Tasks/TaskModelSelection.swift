import AtriumProtocol

/// The same model-menu state for a local task or a mirrored companion task.
nonisolated struct TaskModelSelection: Equatable, Sendable {
    var model: String?
    var reasoningEffort: String?
    var isFastMode: Bool
    var canSelectModel: Bool

    /// The model as its provider lists it, such as "Opus 5.5".
    func modelName(using models: [AgentModel]) -> String? {
        model.map { models.model(running: $0)?.name ?? $0 }
    }
}
