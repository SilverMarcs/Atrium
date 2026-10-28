import Foundation

/// Turns Claude Code transcript lines (`~/.claude/projects/…/<session>.jsonl`) into
/// transcript messages. Each user prompt starts a message; everything the agent
/// writes or runs until the next prompt joins one assistant message.
nonisolated enum ClaudeTranscript {
    /// Older turns are dropped to keep transcripts small enough to send often,
    /// matching Codex's limit. A turn starts with each prompt.
    static let turnLimit = 20

    /// Reads the original embedded bytes, before display thumbnails are made.
    static func imageData(in record: [String: Any]) -> [Data] {
        if let message = record["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            return content.compactMap { block in
                guard block["type"] as? String == "image", let source = block["source"] as? [String: Any],
                      let data = source["data"] as? String else { return nil }
                return Data(base64Encoded: data)
            }
        }
        if let attachment = record["attachment"] as? [String: Any], attachment["type"] as? String == "file",
           let content = attachment["content"] as? [String: Any], content["type"] as? String == "image",
           let file = content["file"] as? [String: Any], let data = file["base64"] as? String,
           let decoded = Data(base64Encoded: data) { return [decoded] }
        return []
    }

    private static let userMarker = Data(#""type":"user""#.utf8)
    private static let toolResultMarker = Data(#""type":"tool_result""#.utf8)
    private static let attachmentMarker = Data(#""type":"attachment""#.utf8)
    private static let queuedCommandMarker = Data(#""type":"queued_command""#.utf8)

    /// The last `turnLimit` turns of the lines, oldest first.
    static func messages(fromLines lines: some Sequence<Data>) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        var assistant: TranscriptMessage?
        func flushAssistant() {
            if let assistant, !assistant.blocks.isEmpty { messages.append(assistant) }
            assistant = nil
        }
        for line in lines {
            guard let record = record(in: line), let uuid = record["uuid"] as? String else { continue }
            let message = record["message"] as? [String: Any]
            switch record["type"] as? String {
            case "user":
                let images = imageData(in: record).compactMap { TranscriptImage.thumbnail($0) }
                let text = promptText(message?["content"]) ?? ""
                guard !text.isEmpty || !images.isEmpty else { continue }
                flushAssistant()
                messages.append(TranscriptMessage(id: uuid, role: .user, blocks: text.isEmpty ? [] : [.text(text, id: uuid)], images: images.isEmpty ? nil : images, editTarget: uuid))
            case "attachment":
                if let attachment = record["attachment"] as? [String: Any], attachment["type"] as? String == "file",
                   let content = attachment["content"] as? [String: Any], content["type"] as? String == "image",
                   let file = content["file"] as? [String: Any], let encoded = file["base64"] as? String,
                   encoded.utf8.count <= 28 * 1024 * 1024, let data = Data(base64Encoded: encoded),
                   let preview = TranscriptImage.thumbnail(data), let user = messages.lastIndex(where: { $0.role == .user }) {
                    messages[user].images = (messages[user].images ?? []) + [preview]
                    if let filename = attachment["filename"] as? String {
                        messages[user].blocks = messages[user].blocks.compactMap { block in
                            guard case .text(let text, let id) = block else { return block }
                            let stripped = text.replacing("@\"\(filename)\"", with: "").replacing("@\(filename)", with: "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            return stripped.isEmpty ? nil : .text(stripped, id: id)
                        }
                    }
                    continue
                }
                // A prompt sent while the agent works joins its turn as an attachment.
                guard let text = steeringText(record["attachment"]) else { continue }
                flushAssistant()
                messages.append(TranscriptMessage(id: uuid, role: .user, blocks: [.text(text, id: uuid)], editTarget: uuid))
            case "assistant":
                var blocks = assistant?.blocks ?? []
                for (index, content) in (message?["content"] as? [[String: Any]] ?? []).enumerated() {
                    append(content, id: "\(uuid).\(index)", to: &blocks)
                }
                guard !blocks.isEmpty else { continue }
                if assistant == nil { assistant = TranscriptMessage(id: uuid, role: .assistant, blocks: []) }
                assistant?.blocks = blocks
            default:
                continue
            }
        }
        flushAssistant()
        let prompts = messages.indices.filter { messages[$0].role == .user }
        guard prompts.count > turnLimit else { return messages }
        return Array(messages[prompts[prompts.count - turnLimit]...])
    }

    /// Whether the line is a prompt, which starts a turn. Most lines are agent
    /// output or tool results, which are ruled out without decoding them.
    static func startsTurn(_ line: Data) -> Bool {
        let isPrompt = contains(userMarker, in: line) && !contains(toolResultMarker, in: line)
        let isSteering = contains(attachmentMarker, in: line) && contains(queuedCommandMarker, in: line)
        guard isPrompt || isSteering, let record = record(in: line) else { return false }
        switch record["type"] as? String {
        case "user": return promptText((record["message"] as? [String: Any])?["content"]) != nil || !imageData(in: record).isEmpty
        case "attachment": return steeringText(record["attachment"]) != nil
        default: return false
        }
    }

    /// A byte search, since tool results can make a line megabytes long.
    private static func contains(_ marker: Data, in line: Data) -> Bool {
        line.withUnsafeBytes { line in
            marker.withUnsafeBytes { marker in
                memmem(line.baseAddress, line.count, marker.baseAddress, marker.count) != nil
            }
        }
    }

    /// The line's record, unless it belongs to a sub-agent or was injected.
    private static func record(in line: Data) -> [String: Any]? {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true else { return nil }
        return record
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

    /// A prompt typed mid-turn, or nil for task notifications and messages from other sessions.
    private static func steeringText(_ attachment: Any?) -> String? {
        guard let attachment = attachment as? [String: Any],
              attachment["type"] as? String == "queued_command",
              attachment["commandMode"] as? String == "prompt",
              ((attachment["origin"] as? [String: Any])?["kind"] as? String ?? "human") == "human" else { return nil }
        return promptText(attachment["prompt"])
    }

    private static func append(_ content: [String: Any], id: String, to blocks: inout [TranscriptBlock]) {
        switch content["type"] as? String {
        case "text":
            guard let text = content["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            blocks.append(.text(text, id: id))
        case "tool_use":
            blocks.appendToolCall(id: id)
        default:
            break
        }
    }
}
