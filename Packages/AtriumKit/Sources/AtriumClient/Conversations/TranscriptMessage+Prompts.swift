import AtriumProtocol

public nonisolated extension [TranscriptMessage] {
    /// The user message showing the `position`th prompt sent after `anchor`,
    /// the newest user message when the first of them was sent, once the
    /// transcript shows it.
    ///
    /// Prompts are recognized by position rather than text, which covers
    /// image-only prompts and providers that normalize the text they store.
    /// Counting from the anchor rather than the start keeps working as older
    /// turns leave the window the host sends.
    func prompt(_ position: Int, after anchor: String?) -> TranscriptMessage? {
        let start = anchor.flatMap { id in firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        let users = self[start...].filter { $0.role == .user }
        guard position > 0, position <= users.count else { return nil }
        return users[position - 1]
    }

    /// The newest prompt in the transcript, which prompts sent next are counted from.
    var promptAnchor: String? {
        last { $0.role == .user }?.id
    }
}
