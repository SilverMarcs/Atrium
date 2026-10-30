import AtriumProtocol
import Foundation

/// A hooked session's chat: Claude's saved history plus what its hooks report as it works.
@MainActor
final class ClaudeLiveTranscript {
    private(set) var messages: [TranscriptMessage]
    private var prompts: Set<String> = []
    private var batches: [String: [Int: String]] = [:]

    init(history: [TranscriptMessage]) { messages = history }

    func prompt(_ text: String, id: String, images: [Data] = []) {
        guard prompts.insert(id).inserted, !text.isEmpty || !images.isEmpty else { return }
        let messageID = "claude-prompt-" + id
        messages.append(TranscriptMessage(id: messageID, role: .user, blocks: text.isEmpty ? [] : [.text(text, id: messageID)], images: images.isEmpty ? nil : images))
        trim()
    }

    func display(_ event: [String: Any]) {
        guard let id = event["message_id"] as? String, let index = event["index"] as? Int,
              let delta = event["delta"] as? String else { return }
        batches[id, default: [:]][index] = delta
        let text = (batches[id] ?? [:]).sorted { $0.key < $1.key }.map(\.value).joined()
        guard !text.isEmpty else { return }
        block(.text(text, id: "claude-display-" + id))
    }

    func tool(_ event: [String: Any]) {
        guard let id = event["tool_use_id"] as? String else { return }
        if messages.last?.role != .assistant {
            messages.append(TranscriptMessage(id: id, role: .assistant, blocks: []))
            trim()
        }
        if event["tool_name"] as? String == AtriumToolServer.claudeRenderHTML, let page = ChatPageStore.page(arguments: event["tool_input"]) {
            messages[messages.count - 1].blocks.append(.page(page, id: id))
        } else {
            messages[messages.count - 1].blocks.appendToolCall(id: id)
        }
    }

    func finish(_ text: String) {
        guard !text.isEmpty, messages.last?.blocks.last?.text != text else { return }
        block(.text(text, id: "claude-result-" + UUID().uuidString))
    }

    private func block(_ block: TranscriptBlock) {
        for index in messages.indices.reversed() {
            if let existing = messages[index].blocks.firstIndex(where: { $0.id == block.id }) {
                messages[index].blocks[existing] = block
                return
            }
        }
        if messages.last?.role == .assistant {
            messages[messages.count - 1].blocks.append(block)
        } else {
            messages.append(TranscriptMessage(id: block.id, role: .assistant, blocks: [block]))
        }
        trim()
    }

    private func trim() {
        if messages.count > 100 { messages.removeFirst(messages.count - 100) }
        if prompts.count > 100 { prompts = Set(prompts.suffix(100)) }
        if batches.count > 100 {
            let ids = Set(messages.flatMap(\.blocks).map(\.id))
            batches = batches.filter { ids.contains("claude-display-" + $0.key) }
        }
    }
}
