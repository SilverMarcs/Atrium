import Foundation

/// Settings typed into a Claude terminal, which its transcript records only with
/// Claude's next reply. They're shown in place of the transcript's own until it
/// reports anything other than it did when they were typed.
struct ClaudeSettingsOverride {
    private let reported: Settings
    private var changes: [AgentSettingsChange] = []

    init(reportedBy thread: AgentThread) {
        reported = Settings(thread)
    }

    mutating func append(_ change: AgentSettingsChange) {
        changes.append(change)
    }

    /// The thread with the typed settings, or nil once its transcript has moved on.
    func applied(to thread: AgentThread) -> AgentThread? {
        guard Settings(thread) == reported else { return nil }
        return changes.reduce(thread) { $1.applying(to: $0) }
    }

    private struct Settings: Equatable {
        let model: String?
        let reasoningEffort: String?
        let isFastMode: Bool?

        init(_ thread: AgentThread) {
            model = thread.model
            reasoningEffort = thread.reasoningEffort
            isFastMode = thread.isFastMode
        }
    }
}
