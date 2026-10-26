import Foundation

/// Turns Claude Code transcript lines (`~/.claude/projects/…/<session>.jsonl`) into
/// transcript messages. Each user prompt starts a message; everything the agent
/// writes or runs until the next prompt joins one assistant message.
nonisolated enum ClaudeTranscript {
    static let messageLimit = 120

    static func messages(fromLines lines: some Sequence<Substring>) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        var assistant: TranscriptMessage?
        func flushAssistant() {
            if let assistant, !assistant.blocks.isEmpty { messages.append(assistant) }
            assistant = nil
        }
        for line in lines {
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let uuid = record["uuid"] as? String,
                  record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true,
                  let message = record["message"] as? [String: Any] else { continue }
            switch record["type"] as? String {
            case "user":
                guard let text = promptText(message["content"]) else { continue }
                flushAssistant()
                messages.append(TranscriptMessage(id: uuid, role: .user, blocks: [.text(text, id: uuid)]))
            case "assistant":
                let blocks = (message["content"] as? [[String: Any]] ?? []).enumerated().compactMap { index, content in
                    block(for: content, id: "\(uuid).\(index)")
                }
                guard !blocks.isEmpty else { continue }
                if assistant == nil { assistant = TranscriptMessage(id: uuid, role: .assistant, blocks: []) }
                assistant?.blocks.append(contentsOf: blocks)
            default:
                continue
            }
        }
        flushAssistant()
        return Array(messages.suffix(messageLimit))
    }

    /// A typed prompt, or nil for tool results, slash-command output and injected context.
    private static func promptText(_ content: Any?) -> String? {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[Request interrupted") else { return nil }
        return trimmed
    }

    private static func block(for content: [String: Any], id: String) -> TranscriptBlock? {
        switch content["type"] as? String {
        case "text":
            guard let text = content["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .text(text, id: id)
        case "tool_use":
            let name = content["name"] as? String ?? "Tool"
            return .tool(name, summary: summary(of: name, input: content["input"] as? [String: Any] ?? [:]), id: id)
        default:
            return nil
        }
    }

    private static func summary(of tool: String, input: [String: Any]) -> String {
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let value: String? = switch tool {
        case "Bash": string("command")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            string("file_path").map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob": string("pattern")
        case "WebFetch": string("url")
        case "WebSearch": string("query")
        case "Task", "Agent": string("description")
        case "TodoWrite": "Updated the plan"
        default: input.values.lazy.compactMap { $0 as? String }.first
        }
        let line = value?.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? tool
        return String(line.prefix(200))
    }
}
