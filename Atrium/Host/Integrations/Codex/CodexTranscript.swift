import Foundation

/// Turns Codex thread turns (app-server `ThreadItem`s) into transcript messages.
/// Reasoning, hook and bookkeeping items are left out; tool items are only counted
/// so clients never receive commands, output or diffs.
nonisolated enum CodexTranscript {
    /// Older turns are dropped to keep transcripts small enough to send often.
    static let turnLimit = 20

    static func messages(fromTurns turns: [[String: Any]]) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        for turn in turns.suffix(turnLimit) {
            guard let turnID = turn["id"] as? String else { continue }
            var segment = 0
            var hasUserMessage = false
            var blocks: [TranscriptBlock] = []
            func flushAssistant() {
                guard !blocks.isEmpty else { return }
                messages.append(TranscriptMessage(id: "\(turnID).\(segment)", role: .assistant, blocks: blocks))
                blocks = []
                segment += 1
            }
            for item in turn["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                if item["type"] as? String == "userMessage" {
                    flushAssistant()
                    let editTarget = hasUserMessage ? nil : turnID
                    hasUserMessage = true
                    let text = (item["content"] as? [[String: Any]] ?? [])
                        .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        .joined(separator: "\n")
                    let images = (item["content"] as? [[String: Any]] ?? []).compactMap { content -> Data? in
                        if content["type"] as? String == "localImage", let path = content["path"] as? String {
                            return TranscriptImage.thumbnail(at: URL(filePath: path))
                        }
                        if content["type"] as? String == "image", let url = content["url"] as? String,
                           url.hasPrefix("data:image/"), url.utf8.count <= 28 * 1024 * 1024,
                           let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])) {
                            return TranscriptImage.thumbnail(data)
                        }
                        return nil
                    }
                    if !text.isEmpty || !images.isEmpty {
                        messages.append(TranscriptMessage(id: id, role: .user, blocks: text.isEmpty ? [] : [.text(text, id: id)], images: images.isEmpty ? nil : images, editTarget: editTarget))
                    }
                } else if item["type"] as? String == "agentMessage" {
                    if let text = item["text"] as? String, !text.isEmpty { blocks.append(.text(text, id: id)) }
                } else if toolTypes.contains(item["type"] as? String ?? "") {
                    blocks.appendToolCall(id: id)
                }
            }
            flushAssistant()
        }
        return messages
    }

    private static let toolTypes: Set = ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch",
                                         "plan", "collabAgentToolCall", "subAgentActivity", "imageGeneration", "imageView"]
}
