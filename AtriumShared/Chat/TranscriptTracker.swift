/// Task and availability distinguish initial placement from live updates;
/// count and newest ID distinguish new messages from growth or shrinking.
nonisolated struct TranscriptTracker: Equatable {
    let taskID: String
    let hasTranscript: Bool
    let count: Int
    let lastID: String?
}
