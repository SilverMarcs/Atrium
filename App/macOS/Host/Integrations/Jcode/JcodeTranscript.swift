import AtriumProtocol
import Foundation

/// Converts the harness history in order. User and assistant rows count toward
/// `/rewind`, including hidden reasoning rows. Tool runs retain Atrium's shared
/// count-only presentation, while their images stay at the provider's boundary.
nonisolated enum JcodeTranscript {
    struct Prompt {
        let ordinal: Int
        let text: String
    }

    struct ToolImage {
        let historyIndex: Int
        let markdown: String
        let replayKey: String?
    }

    static func messages(from rows: [[String: Any]], images: [[String: Any]] = [],
                         renderImage: ([String: Any]) -> String? = { JcodeImageStore.markdown(for: $0) }) -> [TranscriptMessage] {
        messages(from: rows, images: images, toolImages: toolImages(in: images, rowCount: rows.count, renderImage: renderImage))
    }

    static func messages(from rows: [[String: Any]], images: [[String: Any]], toolImages: [ToolImage]) -> [TranscriptMessage] {
        let prompts = promptImages(images)
        let byBoundary = Dictionary(grouping: toolImages, by: \.historyIndex)
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
        func appendImages(at boundary: Int) {
            for image in byBoundary[boundary] ?? [] {
                blocks.append(.text(image.markdown, id: "\(replyID).\(blocks.count)"))
            }
        }
        for (index, row) in rows.enumerated() {
            // Indexes include hidden/system/tool rows, not just visible messages.
            appendImages(at: index)
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
        appendImages(at: rows.count)
        flushReply()
        return messages
    }

    /// Older bridges omit the precise boundary. Keep their image at the end
    /// rather than discarding it or inventing a matching text row.
    static func toolImages(in images: [[String: Any]], rowCount: Int,
                           renderImage: ([String: Any]) -> String?) -> [ToolImage] {
        images.compactMap { image in
            guard !isPromptImage(image) else { return nil }
            let index = image["history_message_index"] as? Int ?? rowCount
            guard (0...rowCount).contains(index), let markdown = renderImage(image) else { return nil }
            return ToolImage(historyIndex: index, markdown: markdown, replayKey: replayKey(for: image, markdown: markdown))
        }
    }

    static func isPromptImage(_ image: [String: Any]) -> Bool {
        let anchor = image["anchor"] as? [String: Any]
        let source = image["source"] as? [String: Any]
        return anchor?["kind"] as? String == "user_prompt" || source?["kind"] as? String == "user_input"
    }

    static func replayKey(for image: [String: Any], markdown: String) -> String? {
        guard let anchor = image["anchor"] as? [String: Any], anchor["kind"] as? String == "tool_call",
              let id = anchor["id"] as? String, !id.isEmpty else { return nil }
        return id + "\u{0}" + (MediaSource.markdownImages(in: markdown).first ?? markdown)
    }

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

    static func promptID(_ ordinal: Int, prompt: String) -> String { "u\(ordinal).\(digest(prompt))" }
    static func replyID(after promptOrdinal: Int, prompt: String) -> String { "a\(promptOrdinal).\(digest(prompt))" }

    /// FNV-1a, stable across launches, unlike `hashValue`.
    private static func digest(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(hash, radix: 36)
    }

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

    /// Reasoning is separately streamed and deliberately not part of the reply.
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
