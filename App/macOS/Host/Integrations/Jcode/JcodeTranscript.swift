import AtriumProtocol
import Foundation

/// Turns Jcode's history rows into transcript messages. Jcode's `/rewind`
/// counts the user and assistant rows, so a prompt's place among them is its
/// edit target, and the agent's reply after it is named by that place too, the
/// same while it streams and once it's saved. Tool rows are only counted, and
/// the reasoning Jcode keeps in its assistant rows is left out.
nonisolated enum JcodeTranscript {
    struct Prompt {
        /// The prompt's place among the user and assistant rows, from 1.
        let ordinal: Int
        let text: String
    }

    static func messages(from rows: [[String: Any]], images: [[String: Any]] = []) -> [TranscriptMessage] {
        let prompts = promptImages(images)
        var messages: [TranscriptMessage] = []
        var ordinal = 0
        var promptCount = 0
        var replyID = replyID(after: 0, prompt: "")
        var blocks: [TranscriptBlock] = []
        func flushReply() {
            guard !blocks.isEmpty else { return }
            messages.append(TranscriptMessage(id: replyID, role: .assistant, blocks: blocks))
            blocks = []
        }
        for row in rows {
            let content = row["content"] as? String ?? ""
            switch row["role"] as? String {
            case "user":
                ordinal += 1
                flushReply()
                let pictures = prompts[promptCount] ?? []
                promptCount += 1
                replyID = Self.replyID(after: ordinal, prompt: content)
                let id = promptID(ordinal, prompt: content)
                guard !content.isEmpty || !pictures.isEmpty else { continue }
                messages.append(TranscriptMessage(
                    id: id, role: .user, blocks: content.isEmpty ? [] : [.text(content, id: id)],
                    images: pictures.isEmpty ? nil : pictures, editTarget: String(ordinal)))
            case "assistant":
                ordinal += 1
                let text = visibleText(content)
                if !text.isEmpty { blocks.append(.text(text, id: "\(replyID).\(blocks.count)")) }
            case "tool":
                blocks.appendToolCall(id: "\(replyID).\(blocks.count)")
            default: continue
            }
        }
        flushReply()
        return messages
    }

    /// The prompts' places, in order, for rewinding to before one.
    static func prompts(in rows: [[String: Any]]) -> [Prompt] {
        var ordinal = 0
        var prompts: [Prompt] = []
        for row in rows {
            switch row["role"] as? String {
            case "user":
                ordinal += 1
                prompts.append(Prompt(ordinal: ordinal, text: row["content"] as? String ?? ""))
            case "assistant": ordinal += 1
            default: continue
            }
        }
        return prompts
    }

    /// A prompt's ID names its place and its text, so a prompt edited in its
    /// place is a new message to clients, as it is in other providers.
    static func promptID(_ ordinal: Int, prompt: String) -> String { "u\(ordinal).\(digest(prompt))" }
    static func replyID(after promptOrdinal: Int, prompt: String) -> String { "a\(promptOrdinal).\(digest(prompt))" }

    /// FNV-1a, stable across launches, unlike `hashValue`.
    private static func digest(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(hash, radix: 36)
    }

    /// The images each prompt carried, by the prompt's place among the prompts, from 0.
    static func promptImages(_ images: [[String: Any]], thumbnails: Bool = true) -> [Int: [Data]] {
        var byPrompt: [Int: [Data]] = [:]
        for image in images {
            guard let anchor = image["anchor"] as? [String: Any], anchor["kind"] as? String == "user_prompt",
                  let index = anchor["ordinal"] as? Int, let encoded = image["data"] as? String,
                  let data = Data(base64Encoded: encoded) else { continue }
            guard let picture = thumbnails ? TranscriptImage.thumbnail(data) : data else { continue }
            byPrompt[index, default: []].append(picture)
        }
        return byPrompt
    }

    /// An assistant row's text without the reasoning Jcode writes into it, one
    /// line at a time, between invisible separators in italics.
    static func visibleText(_ content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !(trimmed.hasPrefix("*\u{2063}") && trimmed.hasSuffix("\u{2063}*"))
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A conversation Atrium has open: its saved history, and what the turn in
/// progress has streamed since, until the history is read again.
@MainActor
final class JcodeLiveConversation {
    private(set) var rows: [[String: Any]] = []
    private var images: [[String: Any]] = []
    private var settled: [TranscriptMessage] = []
    /// A prompt sent since the history was read, shown until it is saved.
    private var sentPrompt: (text: String, images: [Data], isSteer: Bool)?
    private var steers: [(text: String, images: [Data])] = []
    /// The reply streaming now, in order: text by Jcode's message ID, and tool runs.
    private var replyParts: [(messageID: String?, text: String, tools: Int)] = []

    var messages: [TranscriptMessage] {
        var messages = settled
        let prompts = JcodeTranscript.prompts(in: rows)
        var ordinal = rows.reduce(0) { count, row in
            let role = row["role"] as? String
            return role == "user" || role == "assistant" ? count + 1 : count
        }
        var replyOrdinal = prompts.last?.ordinal ?? 0
        var replyPrompt = prompts.last?.text ?? ""
        if let sentPrompt {
            ordinal += 1
            replyOrdinal = ordinal
            replyPrompt = sentPrompt.text
            let id = JcodeTranscript.promptID(ordinal, prompt: sentPrompt.text)
            messages.append(TranscriptMessage(
                id: id, role: .user, blocks: sentPrompt.text.isEmpty ? [] : [.text(sentPrompt.text, id: id)],
                images: sentPrompt.images.isEmpty ? nil : sentPrompt.images, editTarget: String(ordinal)))
        }
        let replyID = JcodeTranscript.replyID(after: replyOrdinal, prompt: replyPrompt)
        var blocks: [TranscriptBlock] = []
        // A reply that had begun when the history was read continues it.
        if messages.last?.id == replyID, let last = messages.popLast() { blocks = last.blocks }
        for part in replyParts {
            if !part.text.isEmpty { blocks.append(.text(JcodeTranscript.visibleText(part.text), id: "\(replyID).\(blocks.count)")) }
            for _ in 0..<part.tools { blocks.appendToolCall(id: "\(replyID).\(blocks.count)") }
        }
        if !blocks.isEmpty { messages.append(TranscriptMessage(id: replyID, role: .assistant, blocks: blocks)) }
        for (index, steer) in steers.enumerated() {
            let id = "steer.\(ordinal).\(index)"
            messages.append(TranscriptMessage(
                id: id, role: .user, blocks: steer.text.isEmpty ? [] : [.text(steer.text, id: id)],
                images: steer.images.isEmpty ? nil : steer.images, isSteer: true))
        }
        return messages
    }

    var hasPrompts: Bool { !JcodeTranscript.prompts(in: rows).isEmpty || sentPrompt != nil }

    func restore(_ history: [String: Any]) {
        rows = history["messages"] as? [[String: Any]] ?? []
        images = history["images"] as? [[String: Any]] ?? []
        settled = JcodeTranscript.messages(from: rows, images: images)
        sentPrompt = nil
        steers.removeAll()
        replyParts.removeAll()
    }

    func send(_ text: String, images: [Data], isSteer: Bool) {
        if isSteer { steers.append((text, images)) }
        else {
            sentPrompt = (text, images, false)
            replyParts.removeAll()
        }
    }

    /// The original images of a prompt, by its edit target.
    func images(ofPrompt editTarget: String) -> [Data] {
        guard let ordinal = Int(editTarget),
              let index = JcodeTranscript.prompts(in: rows).firstIndex(where: { $0.ordinal == ordinal }) else { return [] }
        return JcodeTranscript.promptImages(images, thumbnails: false)[index] ?? []
    }

    /// Applies a streamed event, and says whether the conversation changed.
    func apply(_ event: [String: Any]) -> Bool {
        switch event["ev"] as? String {
        case "text_delta":
            guard let text = event["text"] as? String else { return false }
            let id = event["message_id"] as? String
            if let last = replyParts.last, last.tools == 0, last.messageID == id {
                replyParts[replyParts.count - 1].text += text
            } else {
                replyParts.append((id, text, 0))
            }
            return true
        case "text_replace":
            let id = event["message_id"] as? String
            guard let text = event["text"] as? String,
                  let index = replyParts.lastIndex(where: { $0.messageID == id && $0.tools == 0 }) else { return false }
            replyParts[index].text = text
            return true
        case "tool_start":
            if let last = replyParts.last, last.tools > 0 { replyParts[replyParts.count - 1].tools += 1 }
            else { replyParts.append((nil, "", 1)) }
            return true
        default:
            return false
        }
    }
}
