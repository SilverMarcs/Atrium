import Foundation

/// A session's conversation, built from the `session/update`s Antigravity
/// sends: `session/load` replays a saved one the way a turn streams, so both
/// end up as the same messages with the same IDs. Thoughts are left out, and
/// tool calls are counted, keeping only the latest call's name and one
/// argument, so clients never receive output or diffs.
nonisolated struct AntigravityConversation {
    private enum Entry {
        case prompt(text: String, thumbnails: [Data], isSteer: Bool)
        case reply([Part])
    }

    private enum Part {
        case text(String)
        case tools(Int, latest: TranscriptToolCall?)
        /// A page shown with Atrium's `show_page` tool.
        case page(TranscriptBlock)
    }

    private var entries: [Entry] = []
    private var toolCallIDs: Set<String> = []
    /// The images of prompts sent from Atrium, by message ID. A replay has none.
    private var originals: [String: [Data]] = [:]
    /// Message IDs start with the session's, so a fork's own messages never
    /// share an ID with those it shows from the chat it came from.
    private let sessionID: String

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    var hasPrompts: Bool {
        entries.contains { if case .prompt = $0 { true } else { false } }
    }

    var messages: [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        var ordinal = 0
        for entry in entries {
            switch entry {
            case .prompt(let text, let thumbnails, let isSteer):
                ordinal += 1
                let id = promptID(ordinal)
                messages.append(TranscriptMessage(
                    id: id, role: .user, blocks: text.isEmpty ? [] : [.text(text, id: id)],
                    images: thumbnails.isEmpty ? nil : thumbnails, editTarget: isSteer ? nil : id, isSteer: isSteer))
            case .reply(let parts):
                let id = "\(sessionID).a\(ordinal)"
                var blocks: [TranscriptBlock] = []
                for (index, part) in parts.enumerated() {
                    switch part {
                    case .text(let text): blocks.append(.text(text, id: "\(id).\(index)"))
                    case .tools(let count, let latest): blocks.append(.tools(count: count, latest: latest, id: "\(id).\(index)"))
                    case .page(let page): blocks.append(page)
                    }
                }
                messages.append(TranscriptMessage(id: id, role: .assistant, blocks: blocks))
            }
        }
        return messages
    }

    /// Adds a prompt sent from Atrium. A steer joins the turn in progress.
    mutating func send(_ text: String, images: [Data], thumbnails: [Data], isSteer: Bool) {
        entries.append(.prompt(text: text, thumbnails: thumbnails, isSteer: isSteer))
        let ordinal = entries.reduce(0) { if case .prompt = $1 { $0 + 1 } else { $0 } }
        if !images.isEmpty { originals[promptID(ordinal)] = images }
    }

    /// The original images of a prompt Atrium sent, by its message ID.
    func images(ofPrompt messageID: String) -> [Data] {
        originals[messageID] ?? []
    }

    /// Restores pre-decoded display thumbnails for prompts replayed by `session/load`,
    /// which omits uploaded images; `thumbnailsByPrompt` is indexed 0-based by prompt order.
    mutating func restoreThumbnails(_ thumbnailsByPrompt: [[Data]]) {
        var ordinal = 0
        for index in entries.indices {
            guard case .prompt(let text, let existing, let isSteer) = entries[index] else { continue }
            defer { ordinal += 1 }
            guard existing.isEmpty, thumbnailsByPrompt.indices.contains(ordinal), !thumbnailsByPrompt[ordinal].isEmpty else { continue }
            entries[index] = .prompt(text: text, thumbnails: thumbnailsByPrompt[ordinal], isSteer: isSteer)
        }
    }

    /// Applies a `session/update`, and returns whether the messages changed.
    mutating func apply(_ update: [String: Any]) -> Bool {
        switch update["sessionUpdate"] as? String {
        case "user_message_chunk":
            if let image = Self.image(in: update), let thumbnail = TranscriptImage.thumbnail(image) {
                if case .prompt(let previous, let thumbnails, let isSteer)? = entries.last {
                    entries[entries.count - 1] = .prompt(text: previous, thumbnails: thumbnails + [thumbnail], isSteer: isSteer)
                } else {
                    entries.append(.prompt(text: "", thumbnails: [thumbnail], isSteer: false))
                }
                let ordinal = entries.reduce(0) { if case .prompt = $1 { $0 + 1 } else { $0 } }
                originals[promptID(ordinal), default: []].append(image)
                return true
            }
            // A resource Atrium sent with a prompt, such as a side chat's boundary, replays as its own piece.
            guard let text = Self.text(in: update), !text.hasPrefix("Content of atrium://") else { return false }
            // A replayed prompt can arrive in pieces.
            if case .prompt(let previous, let thumbnails, let isSteer)? = entries.last {
                entries[entries.count - 1] = .prompt(text: previous + text, thumbnails: thumbnails, isSteer: isSteer)
            } else {
                entries.append(.prompt(text: text, thumbnails: [], isSteer: false))
            }
            return true
        case "agent_message_chunk":
            guard let text = Self.text(in: update), !text.isEmpty else { return false }
            if case .reply(let parts)? = entries.last, case .text(let previous)? = parts.last {
                appendToReply { parts in
                    parts[parts.count - 1] = .text(previous + text)
                }
                return true
            }
            // Antigravity prefixes later planner responses with blank lines for plain-text streams;
            // strip them when starting a new block after tool calls so Steps rows don't show leading blanks.
            let trimmed = String(text.drop(while: \.isNewline))
            guard !trimmed.isEmpty else { return false }
            appendToReply { parts in
                parts.append(.text(trimmed))
            }
            return true
        case "tool_call":
            guard let id = update["toolCallId"] as? String, toolCallIDs.insert(id).inserted else { return false }
            if let page = ChatPages.page(forTool: update["name"] as? String, arguments: update["rawInput"], id: "\(sessionID).\(id)") {
                appendToReply { $0.append(.page(page)) }
                return true
            }
            let call = TranscriptToolCall(name: update["name"] as? String, arguments: update["rawInput"])
            appendToReply { parts in
                if case .tools(let count, _)? = parts.last {
                    parts[parts.count - 1] = .tools(count + 1, latest: call)
                } else {
                    parts.append(.tools(1, latest: call))
                }
            }
            return true
        default:
            return false
        }
    }

    private mutating func appendToReply(_ change: (inout [Part]) -> Void) {
        var parts: [Part] = []
        if case .reply(let existing)? = entries.last {
            parts = existing
            entries.removeLast()
        }
        change(&parts)
        entries.append(.reply(parts))
    }

    private static func text(in update: [String: Any]) -> String? {
        guard let content = update["content"] as? [String: Any], content["type"] as? String == "text" else { return nil }
        return content["text"] as? String
    }

    private static func image(in update: [String: Any]) -> Data? {
        guard let content = update["content"] as? [String: Any], content["type"] as? String == "image",
              let encoded = content["data"] as? String, encoded.utf8.count <= 28 * 1024 * 1024 else { return nil }
        return Data(base64Encoded: encoded)
    }

    private func promptID(_ ordinal: Int) -> String { "\(sessionID).u\(ordinal)" }

    /// A prompt's place among the prompts, from 1, by its message ID.
    static func ordinal(ofPrompt messageID: String) -> Int? {
        messageID.split(separator: ".").last.flatMap { $0.first == "u" ? Int($0.dropFirst()) : nil }
    }
}
