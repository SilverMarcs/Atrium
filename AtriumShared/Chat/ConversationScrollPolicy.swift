/// Initial layout stays at the bottom without animation, even while Markdown
/// finishes measuring. Only a new message or an explicit send enables animation.
nonisolated struct ConversationScrollPolicy {
    private(set) var animatesGrowth = false

    /// Returns true when the viewport should reset to its initial bottom anchor.
    mutating func observe(from old: TranscriptTracker, to new: TranscriptTracker, preservingTurn: Bool = false) -> Bool {
        if !preservingTurn && (old == new || old.taskID != new.taskID || old.hasTranscript != new.hasTranscript) {
            animatesGrowth = false
            return true
        }
        if new.lastID != old.lastID, new.count >= old.count {
            animatesGrowth = true
        }
        return false
    }

    mutating func noteSend() {
        animatesGrowth = true
    }
}
