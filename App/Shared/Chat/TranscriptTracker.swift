/// Task and availability distinguish initial placement from live updates;
/// count and newest ID distinguish new messages from growth or shrinking.
nonisolated struct TranscriptTracker: Equatable {
    let taskID: String
    let hasTranscript: Bool
    let count: Int
    let lastID: String?
    /// The row of the prompt waiting for the turn to end, which becomes the
    /// newest prompt in its place once the host sends it.
    var queuedRowID: String? = nil
}
