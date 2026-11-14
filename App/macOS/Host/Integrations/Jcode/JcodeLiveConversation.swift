import AtriumProtocol
import Foundation

/// A saved history plus the ordered text, tool runs and images streaming since
/// that snapshot. Tool image bytes live on disk, not in the retained history.
@MainActor
final class JcodeLiveConversation {
    private enum Part {
        case text(messageID: String?, content: String)
        case tool
        case image(String)
    }

    private(set) var rows: [[String: Any]] = []
    private var images: [[String: Any]] = []
    private var settled: [TranscriptMessage] = []
    private var sentPrompt: (text: String, images: [Data])?
    private var steers: [(text: String, images: [Data])] = []
    private var replyParts: [Part] = []
    private var activeTextIndex: Int?
    private var toolIDs: Set<String> = []
    private var imageCounts: [String: Int] = [:]
    private let renderImage: ([String: Any]) -> String?

    init(renderImage: @escaping ([String: Any]) -> String? = { JcodeImageStore.markdown(for: $0) }) {
        self.renderImage = renderImage
    }

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
        if messages.last?.id == replyID, let last = messages.popLast() { blocks = last.blocks }
        for (index, part) in replyParts.enumerated() {
            // A retracted text part keeps its position, so later block IDs stay stable.
            let id = "\(replyID).live.\(index)"
            switch part {
            case .text(_, let content):
                let text = JcodeTranscript.visibleText(content)
                if !text.isEmpty { blocks.append(.text(text, id: id)) }
            case .tool:
                blocks.appendToolCall(id: id)
            case .image(let markdown):
                blocks.append(.text(markdown, id: id))
            }
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
        let allImages = history["images"] as? [[String: Any]] ?? []
        let toolImages = JcodeTranscript.toolImages(in: allImages, rowCount: rows.count, renderImage: renderImage)
        // Only prompt originals need to stay for the existing prompt-image API.
        // Tool originals are now durable files referenced by small Markdown blocks.
        images = allImages.filter(JcodeTranscript.isPromptImage)
        settled = JcodeTranscript.messages(from: rows, images: images, toolImages: toolImages)
        imageCounts = [:]
        for image in toolImages {
            if let key = image.replayKey { imageCounts[key, default: 0] += 1 }
        }
        sentPrompt = nil
        steers.removeAll()
        replyParts.removeAll()
        toolIDs.removeAll()
        activeTextIndex = nil
    }

    func send(_ text: String, images: [Data], isSteer: Bool) {
        if isSteer { steers.append((text, images)) }
        else {
            sentPrompt = (text, images)
            replyParts.removeAll()
            toolIDs.removeAll()
            activeTextIndex = nil
        }
    }

    func images(ofPrompt editTarget: String) -> [Data] {
        guard let ordinal = Int(editTarget),
              let index = JcodeTranscript.prompts(in: rows).firstIndex(where: { $0.ordinal == ordinal }) else { return [] }
        return JcodeTranscript.promptImages(images, thumbnails: false)[index] ?? []
    }

    func apply(_ event: [String: Any]) -> Bool {
        let messageID = event["message_id"] as? String
        switch event["ev"] as? String {
        case "text_delta":
            guard let text = event["text"] as? String, !text.isEmpty else { return false }
            // Tool argument streaming may interleave without ending this message.
            let index = messageID == nil ? activeTextIndex : textIndex(for: messageID)
            if let index, case .text(let id, let content) = replyParts[index] {
                replyParts[index] = .text(messageID: id, content: content + text)
                activeTextIndex = index
            } else {
                replyParts.append(.text(messageID: messageID, content: text))
                activeTextIndex = replyParts.count - 1
            }
            return true
        case "text_replace":
            guard let text = event["text"] as? String else { return false }
            if let index = textIndex(for: messageID) {
                replyParts[index] = .text(messageID: messageID, content: text)
            } else if !text.isEmpty {
                // Recovered output may first arrive as a replacement, without a delta.
                replyParts.append(.text(messageID: messageID, content: text))
                activeTextIndex = replyParts.count - 1
            } else { return false }
            return true
        case "text_done":
            if let index = activeTextIndex, case .text(let id, _) = replyParts[index], id == messageID {
                activeTextIndex = nil
            }
            return false
        case "tool_start":
            if let id = event["call_id"] as? String, !id.isEmpty {
                guard toolIDs.insert(id).inserted else { return false }
            }
            replyParts.append(.tool)
            return true
        case "tool_exec":
            activeTextIndex = nil
            return false
        case "side_pane_images":
            return appendImages(event["images"] as? [[String: Any]] ?? [])
        default:
            return false
        }
    }

    private func textIndex(for messageID: String?) -> Int? {
        replyParts.lastIndex { part in
            if case .text(let id, _) = part { id == messageID } else { false }
        }
    }

    private func appendImages(_ images: [[String: Any]]) -> Bool {
        var occurrences: [String: Int] = [:]
        var changed = false
        for image in images {
            guard !JcodeTranscript.isPromptImage(image), let markdown = renderImage(image) else { continue }
            if let key = JcodeTranscript.replayKey(for: image, markdown: markdown) {
                occurrences[key, default: 0] += 1
                let occurrence = occurrences[key, default: 0]
                // Preserve repeated images within a batch, but not replayed batches
                // or an image already included in the just-restored snapshot.
                guard occurrence > imageCounts[key, default: 0] else { continue }
                imageCounts[key] = occurrence
            }
            replyParts.append(.image(markdown))
            changed = true
        }
        return changed
    }
}
