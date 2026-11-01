import AtriumProtocol

/// The same model-menu state for a local task or a mirrored companion task.
nonisolated struct TaskModelSelection: Equatable, Sendable {
    var model: String?
    var reasoningEffort: String?
    var isFastMode: Bool
    var canSelectModel: Bool
    /// How much of the model's context the conversation uses, in percent, when known.
    var contextUsedPercent: Int? = nil

    func summary(using models: [AgentModel]) -> String? {
        guard let model else { return nil }
        return [
            models.model(running: model)?.name ?? model,
            reasoningEffort.map(AgentModel.effortName),
            isFastMode ? "Fast" : nil
        ].compactMap(\.self).joined(separator: " · ")
    }
}
