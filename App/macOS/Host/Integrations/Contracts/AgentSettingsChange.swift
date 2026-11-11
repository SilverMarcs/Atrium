/// A change to the model settings a thread's next turns use, chosen from one
/// the provider lists.
enum AgentSettingsChange: Sendable {
    /// A model, and its reasoning effort when it has any.
    case model(String, reasoningEffort: String?)
    case fastMode(Bool)

    func applying(to source: AgentThread) -> AgentThread {
        var thread = source
        switch self {
        case .model(let model, let reasoningEffort):
            thread.model = model
            if let reasoningEffort { thread.reasoningEffort = reasoningEffort }
        case .fastMode(let isOn):
            thread.isFastMode = isOn
        }
        return thread
    }
}
