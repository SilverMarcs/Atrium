import AtriumProtocol

/// Where a fork through a finished reply ends: before the prompt that came
/// after it, or at the chat's end for the latest reply. Providers fork at
/// prompts, so a reply followed by a prompt the host can't fork at yet, such
/// as one still on its way, has none.
nonisolated enum ReplyForkPoint: Hashable {
    case end
    case before(editTarget: String)

    /// The prompt the fork stops before, or nil for the whole chat.
    var editTarget: String? {
        switch self {
        case .end: nil
        case .before(let editTarget): editTarget
        }
    }

    /// The fork point of each finished reply in a timeline, by message ID.
    /// Finished turns fold into one reply each, so the message after one is
    /// the prompt that starts the next turn. `hasLaterPrompts` says prompts
    /// not in `messages` follow them.
    static func points(in messages: [TranscriptMessage], liveIDs: Set<String>, hasLaterPrompts: Bool = false) -> [String: ReplyForkPoint] {
        var points: [String: ReplyForkPoint] = [:]
        var next: ReplyForkPoint? = hasLaterPrompts ? nil : .end
        for message in messages.reversed() {
            switch message.role {
            case .user:
                next = message.editTarget.map { .before(editTarget: $0) }
            case .assistant:
                if !liveIDs.contains(message.id), let next { points[message.id] = next }
            }
        }
        return points
    }
}
