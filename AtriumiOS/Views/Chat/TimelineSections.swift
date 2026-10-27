/// A timeline's rows split around the prompt that starts its latest turn:
/// the history before it, and the turn itself.
struct TimelineSections {
    var historyMessages: [TranscriptMessage]
    var historyPendingPrompts: [PendingPrompt]
    var turnMessages: [TranscriptMessage] = []
    var turnPendingPrompts: [PendingPrompt] = []
    /// Whether a prompt starts a turn, rather than everything being history.
    var hasTurn = false

    init(messages: [TranscriptMessage], pendingPrompts: [PendingPrompt], anchorID: String?) {
        historyMessages = messages
        historyPendingPrompts = pendingPrompts
        guard let anchorID else { return }
        if let index = pendingPrompts.firstIndex(where: { $0.timelineID == anchorID }) {
            historyPendingPrompts = Array(pendingPrompts[..<index])
            turnPendingPrompts = Array(pendingPrompts[index...])
            hasTurn = true
        } else if let index = messages.firstIndex(where: { $0.id == anchorID }) {
            historyMessages = Array(messages[..<index])
            turnMessages = Array(messages[index...])
            historyPendingPrompts = []
            turnPendingPrompts = pendingPrompts
            hasTurn = true
        }
    }
}
