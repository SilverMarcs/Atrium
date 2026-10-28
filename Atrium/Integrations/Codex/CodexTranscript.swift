import Foundation

/// Turns Codex thread turns (app-server `ThreadItem`s) into transcript messages.
/// Reasoning, hook and bookkeeping items are left out; tool items become one-line
/// summaries so the companion never receives command output or diffs.
nonisolated enum CodexTranscript {
    /// Older turns are dropped to keep transcripts small enough to send often.
    static let turnLimit = 20

    static func messages(fromTurns turns: [[String: Any]]) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        for turn in turns.suffix(turnLimit) {
            guard let turnID = turn["id"] as? String else { continue }
            var segment = 0
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
                        messages.append(TranscriptMessage(id: id, role: .user, blocks: text.isEmpty ? [] : [.text(text, id: id)], images: images.isEmpty ? nil : images))
                    }
                } else if let block = block(for: item, id: id) {
                    blocks.append(block)
                }
            }
            flushAssistant()
        }
        return messages
    }

    private static func block(for item: [String: Any], id: String) -> TranscriptBlock? {
        switch item["type"] as? String {
        case "agentMessage":
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            return .text(text, id: id)
        case "commandExecution":
            return .tool("Bash", summary: shellCommand(item["command"] as? String ?? ""), id: id)
        case "fileChange":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            return .tool("Edit", summary: paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "), id: id)
        case "mcpToolCall":
            let tool = item["tool"] as? String ?? "tool"
            return .tool(tool, summary: [item["server"] as? String, tool].compactMap(\.self).joined(separator: "."), id: id)
        case "dynamicToolCall":
            let tool = item["tool"] as? String ?? "tool"
            return .tool(tool, summary: tool, id: id)
        case "webSearch":
            return .tool("WebSearch", summary: item["query"] as? String ?? "Web search", id: id)
        case "plan":
            let text = item["text"] as? String ?? ""
            return .tool("Plan", summary: text.split(separator: "\n").first.map(String.init) ?? "Plan", id: id)
        case "collabAgentToolCall", "subAgentActivity":
            return .tool("Agent", summary: (item["prompt"] as? String).map { String($0.prefix(120)) } ?? "Sub-agent", id: id)
        case "imageGeneration", "imageView":
            return .tool("Image", summary: "Image", id: id)
        default:
            return nil
        }
    }

    /// Strips the login-shell wrapper Codex runs commands in.
    private static func shellCommand(_ command: String) -> String {
        guard let match = command.wholeMatch(of: /\/bin\/(?:z|ba)?sh -lc (['"])(.*)\1/.dotMatchesNewlines()) else { return command }
        return String(match.2)
    }
}
