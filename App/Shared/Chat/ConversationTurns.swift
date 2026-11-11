import AtriumClient
import AtriumProtocol
import Foundation

/// A conversation's messages grouped by turn. A steer, a prompt sent while the
/// agent works, joins the turn it was sent into rather than starting one.
///
/// While a turn runs, its messages stay in the order they happened and all of
/// its replies show their work. Once it ends, its steers move up under the
/// prompt that started it and its replies become one, so the turn folds like
/// any other.
struct ConversationTurns {
    /// Finished turns folded, then the running turn as it happened.
    let messages: [TranscriptMessage]
    /// The running turn's replies.
    let liveIDs: Set<String>
    /// Pages a later page with the same title revised, by block ID.
    let earlierPageIDs: Set<String>

    init(messages: [TranscriptMessage], pendingPrompts: [PendingPrompt], status: AgentThreadStatus) {
        // A prompt on its way that isn't a steer starts a new turn, so the one
        // before it has finished, even once the agent starts on that prompt.
        let isRunning = (status == .processing || status == .waiting)
            && !pendingPrompts.contains { !$0.isSteer && $0.state != .failed }
        let start = isRunning ? messages.lastIndex { $0.role == .user && !$0.isSteer } ?? 0 : messages.endIndex
        let running = messages[start...]
        self.messages = Self.fold(messages[..<start]) + running
        liveIDs = Set(running.filter { $0.role == .assistant }.map(\.id))
        earlierPageIDs = Self.earlierPages(in: messages)
    }

    /// An agent revises a page by showing it again in full, usually under the
    /// same title, so every version but the last one with a title is earlier.
    private static func earlierPages(in messages: [TranscriptMessage]) -> Set<String> {
        var latest: [String: String] = [:]
        var earlier: Set<String> = []
        for block in messages.lazy.filter({ $0.role == .assistant }).flatMap(\.blocks) {
            guard let page = block.page else { continue }
            let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let previous = latest.updateValue(block.id, forKey: title) { earlier.insert(previous) }
        }
        return earlier
    }

    private static func fold(_ messages: ArraySlice<TranscriptMessage>) -> [TranscriptMessage] {
        var folded: [TranscriptMessage] = []
        // Where the current turn's reply is, once it has one.
        var reply: Int?
        for message in messages {
            switch message.role {
            case .user where message.isSteer:
                guard let index = reply else {
                    folded.append(message)
                    continue
                }
                folded.insert(message, at: index)
                reply = index + 1
            case .user:
                folded.append(message)
                reply = nil
            case .assistant:
                if let reply {
                    folded[reply].blocks += message.blocks
                } else {
                    folded.append(message)
                    reply = folded.count - 1
                }
            }
        }
        return folded
    }
}
