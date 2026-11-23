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
    /// The last page in the newest turn's reply, so a page an agent just
    /// showed can open somewhere bigger as it arrives.
    let newestPage: ChatPageBlock?

    init(messages: [TranscriptMessage], pendingPrompts: [PendingPrompt], status: AgentThreadStatus) {
        // A prompt on its way that isn't a steer starts a new turn, so the one
        // before it has finished, even once the agent starts on that prompt.
        let isRunning = (status == .processing || status == .waiting)
            && !pendingPrompts.contains { !$0.isSteer }
        let start = isRunning ? messages.lastIndex { $0.role == .user && !$0.isSteer } ?? 0 : messages.endIndex
        let running = messages[start...]
        self.messages = Self.fold(messages[..<start]) + running
        liveIDs = Set(running.filter { $0.role == .assistant }.map(\.id))
        earlierPageIDs = Set(Self.pageVersions(in: messages).flatMap { $0.dropLast() }.map(\.id))
        newestPage = Self.newestPage(in: messages)
    }

    private static func newestPage(in messages: [TranscriptMessage]) -> ChatPageBlock? {
        for message in messages.reversed() {
            switch message.role {
            case .user where message.isSteer:
                continue
            case .user:
                return nil
            case .assistant:
                if let block = message.blocks.last(where: { $0.page != nil }), let page = block.page {
                    return ChatPageBlock(page: page, id: block.id)
                }
            }
        }
        return nil
    }

    /// Each page the chat showed, most recently shown first, with its versions
    /// oldest first. An agent revises a page by showing it again in full,
    /// usually under the same title.
    static func pageVersions(in messages: [TranscriptMessage]) -> [[ChatPageBlock]] {
        var versions: [String: [ChatPageBlock]] = [:]
        var order: [String] = []
        for block in messages.lazy.filter({ $0.role == .assistant }).flatMap(\.blocks) {
            // A page still being written has no key yet.
            guard let page = block.page, page.key != nil else { continue }
            let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            versions[title, default: []].append(ChatPageBlock(page: page, id: block.id))
            order.removeAll { $0 == title }
            order.append(title)
        }
        return order.reversed().compactMap { versions[$0] }
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

/// A page an agent showed, with the block that shows it.
struct ChatPageBlock: Equatable {
    let page: TranscriptPage
    let id: String
}
