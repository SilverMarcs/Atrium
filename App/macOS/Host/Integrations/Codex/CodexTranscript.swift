import AtriumProtocol
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
                    // Later prompts in a turn were steered into it.
                    let isSteer = hasUserMessage
                    let editTarget = isSteer ? nil : turnID
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
                        messages.append(TranscriptMessage(id: id, role: .user, blocks: text.isEmpty ? [] : [.text(text, id: id)], images: images.isEmpty ? nil : images, editTarget: editTarget, isSteer: isSteer))
                    }
                } else if let report = report(in: item) {
                    // A subagent reporting back is input to the agent, not part of its reply.
                    flushAssistant()
                    messages.append(TranscriptMessage(id: id, role: .user, blocks: [], relay: report))
                } else if item["type"] as? String == "agentMessage" {
                    if let text = item["text"] as? String, !text.isEmpty { blocks.append(.text(text, id: id)) }
                } else if let image = generatedImage(in: item) {
                    blocks.append(.text(image, id: id))
                } else if toolTypes.contains(item["type"] as? String ?? "") {
                    blocks.appendToolCall(id: id)
                }
            }
            flushAssistant()
        }
        return messages
    }

    /// A subagent's report reaching its session. The host names it as it lists
    /// the subagent's thread, and by the path Codex gave it until then.
    private static func report(in item: [String: Any]) -> TranscriptRelay? {
        guard item["type"] as? String == "subAgentActivity", item["kind"] as? String == "completed" else { return nil }
        let path = (item["agentPath"] as? String)?.split(separator: "/").last.map(String.init)
        let name = [AgentProvider.codex.name, path].compactMap(\.self).joined(separator: " · ")
        return TranscriptRelay(kind: .results, senders: [.init(name: name, sessionID: item["agentThreadId"] as? String)])
    }

    /// A finished generated image, as Markdown pointing to the file Codex saved it to.
    private static func generatedImage(in item: [String: Any]) -> String? {
        guard item["type"] as? String == "imageGeneration", item["status"] as? String == "completed",
              let path = item["savedPath"] as? String, !path.isEmpty else { return nil }
        return MediaSource.markdownImage(path: path)
    }

    private static let toolTypes: Set = ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch",
                                         "plan", "collabAgentToolCall", "subAgentActivity", "imageGeneration", "imageView"]
}
