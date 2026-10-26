/// The newest message and the message count, which together tell a new
/// message from the newest one growing or the transcript shrinking.
struct TranscriptTracker: Equatable {
    let count: Int
    let lastID: String?
}
