import AtriumProtocol
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
@MainActor
enum JcodeTranscriptChecks {
    struct CheckFailure: Error { let message: String }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }

    static func png() throws -> Data {
        let pixels = Data([20, 80, 160, 255])
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CheckFailure(message: "Create fixture image")
        }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw CheckFailure(message: "Create fixture encoder")
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw CheckFailure(message: "Encode fixture") }
        return output as Data
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "JcodeTranscriptChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let render: ([String: Any]) -> String? = { JcodeImageStore.markdown(for: $0, directory: directory) }
        let png = try png()
        let image: [String: Any] = [
            "data": png.base64EncodedString(), "label": "Screenshot", "media_type": "image/png",
            "source": ["kind": "tool_result", "tool_name": "browser"],
            "anchor": ["kind": "tool_call", "id": "capture"], "history_message_index": 3
        ]
        let rows: [[String: Any]] = [
            ["role": "user", "content": "Show the result"],
            ["role": "assistant", "content": "Capturing"],
            ["role": "tool", "content": "Captured screenshot"],
            ["role": "assistant", "content": "Done"]
        ]
        let messages = JcodeTranscript.messages(from: rows, images: [image], renderImage: render)
        let texts = messages.flatMap(\.blocks).compactMap(\.text)
        try check(texts.contains { !MediaSource.markdownImages(in: $0).isEmpty }, "Tool-returned screenshot must be restored")
        guard let markdown = texts.first(where: { !MediaSource.markdownImages(in: $0).isEmpty }),
              let path = MediaSource.markdownImages(in: markdown).first else { throw CheckFailure(message: "Missing image reference") }
        try check(try Data(contentsOf: URL(filePath: path)) == png, "Keep full-resolution original bytes")
        try check(texts == ["Show the result", "Capturing", markdown, "Done"], "Keep screenshot between its tool and following text")
        let reply = AssistantReply(blocks: messages[1].blocks, isStreaming: false)
        try check(reply.text == markdown + "\n\nDone", "Keep a tool screenshot visible with the closing reply after its tool run")
        let thread = AgentThread(sessionID: "images", provider: .jcode, title: "Images",
                                 directory: "/unrelated/project", updatedAt: .now, status: .idle)
        let media = TranscriptMedia()
        media.record(messages, of: thread)
        let resolvedPath = TranscriptMedia.resolve(path, in: thread.directory)
        try check(media.shows(image: resolvedPath, in: thread.id), "Authorize the durable image outside the project through the shared Mac/iOS media path")
        try check(!media.shows(image: resolvedPath, in: "jcode:another-task"), "An image reference authorizes only the task that showed it")
        try check(!media.shows(image: directory.appending(path: "unshown.png").path, in: thread.id), "Do not authorize unshown cache files")
        try check(TranscriptImage.thumbnail(try Data(contentsOf: URL(filePath: resolvedPath))) != nil, "The authorized original must decode for display")

        var secondImage = image
        secondImage["label"] = "Second image"
        let pair = JcodeTranscript.messages(from: rows, images: [image, secondImage], renderImage: render)
        let pairMarkdown = imageMarkdown(in: pair)
        try check(pairMarkdown.count == 2 && pairMarkdown[0] == markdown && pairMarkdown[1].contains("Second image"), "Preserve provider vector order at the same boundary")
        var withHidden = rows
        withHidden.insert(["role": "system", "content": "hidden"], at: 3)
        var hiddenImage = image
        hiddenImage["history_message_index"] = 4
        let hidden = JcodeTranscript.messages(from: withHidden, images: [hiddenImage], renderImage: render)
        try check(shape(hidden) == shape(messages), "Image boundaries count hidden rows")
        let nextPrompt: [String: Any] = ["role": "user", "content": "Next"]
        var endImage = image
        endImage["history_message_index"] = rows.count
        let beforePrompt = JcodeTranscript.messages(from: rows + [nextPrompt], images: [endImage], renderImage: render)
        try check(imageMarkdown(in: [beforePrompt[1]]).count == 1 && beforePrompt.last?.role == .user, "An image before a user row belongs to the preceding reply")
        let baseline = JcodeTranscript.messages(from: rows + [nextPrompt])
        try check(beforePrompt.filter { $0.role == .user }.map(\.editTarget) == baseline.filter { $0.role == .user }.map(\.editTarget), "Images do not change rewind targets")
        var invalid = image
        invalid["history_message_index"] = -1
        var tooLate = image
        tooLate["history_message_index"] = rows.count + 1
        try check(imageMarkdown(in: JcodeTranscript.messages(from: rows, images: [invalid, tooLate], renderImage: render)).isEmpty, "Reject out-of-range boundaries")
        var legacy = image
        legacy.removeValue(forKey: "history_message_index")
        try check(imageMarkdown(in: JcodeTranscript.messages(from: rows, images: [legacy], renderImage: render)).count == 1, "Older histories must not silently lose images")

        let live = JcodeLiveConversation(renderImage: render)
        live.send("Show the result", images: [], isSteer: false)
        _ = live.apply(["ev": "text_delta", "message_id": "m1", "text": "Before"])
        _ = live.apply(["ev": "tool_start", "call_id": "capture", "name": "browser"])
        _ = live.apply(["ev": "text_delta", "message_id": "m1", "text": " text"])
        _ = live.apply(["ev": "text_replace", "message_id": "m1", "text": "Corrected"])
        let corrected = live.messages.flatMap(\.blocks).compactMap(\.text)
        try check(corrected == ["Show the result", "Corrected"], "Replace the entire stream message, not just its last fragment")
        _ = live.apply(["ev": "text_done", "message_id": "m1"])
        _ = live.apply(["ev": "text_delta", "message_id": "m2", "text": "Other"])
        _ = live.apply(["ev": "text_replace", "message_id": "m1", "text": ""])
        try check(!live.messages.flatMap(\.blocks).compactMap(\.text).contains("Corrected"), "Rollback retracts even completed text")
        _ = live.apply(["ev": "text_replace", "message_id": "recovered", "text": "Recovered output"])
        try check(live.messages.flatMap(\.blocks).compactMap(\.text).contains("Recovered output"), "Recover a replacement without earlier deltas")

        let streaming = JcodeLiveConversation(renderImage: render)
        streaming.send("Show the result", images: [], isSteer: false)
        _ = streaming.apply(["ev": "text_delta", "message_id": "a", "text": "Capturing"])
        _ = streaming.apply(["ev": "text_done", "message_id": "a"])
        _ = streaming.apply(["ev": "tool_start", "call_id": "capture", "name": "browser"])
        try check(!streaming.apply(["ev": "tool_start", "call_id": "capture", "name": "browser"]), "Replayed tool starts do not inflate counts")
        let imageEvent: [String: Any] = ["ev": "side_pane_images", "images": [image]]
        try check(streaming.apply(imageEvent), "Show a live tool screenshot immediately")
        try check(!streaming.apply(imageEvent), "Do not duplicate a replayed image batch")
        _ = streaming.apply(["ev": "text_delta", "message_id": "b", "text": "Done"])
        try check(shape(streaming.messages) == shape(messages), "Live and restored transcript order must agree")
        streaming.restore(["messages": rows, "images": [image]])
        try check(shape(streaming.messages) == shape(messages), "Settling a turn must not change its visible content")
        try check(!streaming.apply(imageEvent), "A restored image must not duplicate on event replay")
        let restored = JcodeLiveConversation(renderImage: render)
        restored.restore(["messages": rows, "images": [image]])
        try check(shape(restored.messages) == shape(messages), "Reconnect/relaunch rebuilds the same references")
        try check(restored.images(ofPrompt: "1").isEmpty, "Tool images are not user attachments")

        let repeated = JcodeLiveConversation(renderImage: render)
        repeated.send("Show the result", images: [], isSteer: false)
        let repeatedEvent: [String: Any] = ["ev": "side_pane_images", "images": [image, secondImage]]
        try check(repeated.apply(repeatedEvent) && imageMarkdown(in: repeated.messages).count == 2, "Preserve identical bytes twice within one batch")
        try check(!repeated.apply(repeatedEvent), "Do not repeat that whole batch on replay")
        var otherCall = image
        otherCall["anchor"] = ["kind": "tool_call", "id": "capture-again"]
        try check(repeated.apply(["ev": "side_pane_images", "images": [otherCall]]), "Identical pixels from another tool call are a separate screenshot occurrence")
        try check(imageMarkdown(in: repeated.messages).count == 3, "Content-addressed files must not collapse separate tool results")
        repeated.restore(["messages": rows, "images": []])
        try check(repeated.apply(imageEvent), "Restoring a history without an image clears its replay suppression")

        let promptImage: [String: Any] = ["data": png.base64EncodedString(), "anchor": ["kind": "user_prompt", "ordinal": 0], "source": ["kind": "user_input"]]
        restored.restore(["messages": rows, "images": [promptImage, image]])
        try check(restored.images(ofPrompt: "1") == [png] && restored.messages[0].images?.count == 1, "Retain prompt originals and previews")
        try check(imageMarkdown(in: restored.messages).count == 1, "Do not duplicate prompt images into the reply")
        let reasoned = JcodeTranscript.messages(from: [["role": "user", "content": "Question"], ["role": "assistant", "content": "*\u{2063}private reasoning\u{2063}*  \n\nAnswer"]])
        try check(reasoned.last?.blocks.compactMap(\.text) == ["Answer"], "Keep reasoning separate from public reply")
        if let filename = CommandLine.arguments.dropFirst().first { try checkRealHistory(at: filename, renderImage: render) }
        print("Jcode transcript checks passed")
    }

    static func imageMarkdown(in messages: [TranscriptMessage]) -> [String] {
        messages.flatMap(\.blocks).compactMap(\.text).filter { !MediaSource.markdownImages(in: $0).isEmpty }
    }

    static func shape(_ messages: [TranscriptMessage]) -> [String] {
        messages.flatMap { message in
            [message.role.rawValue] + message.blocks.map { block in
                if let text = block.text { return text }
                return "tools:\(block.toolCount)"
            }
        }
    }

    static func checkRealHistory(at filename: String, renderImage: @escaping ([String: Any]) -> String?) throws {
        let raw = try Data(contentsOf: URL(filePath: filename))
        guard let history = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let rows = history["messages"] as? [[String: Any]], let images = history["images"] as? [[String: Any]] else {
            throw CheckFailure(message: "Read actual harness history")
        }
        let messages = JcodeTranscript.messages(from: rows, images: images, renderImage: renderImage)
        let allReferences = imageMarkdown(in: messages).flatMap(MediaSource.markdownImages)
        let toolImages = images.enumerated().filter { !JcodeTranscript.isPromptImage($0.element) }.sorted {
            let lhs = $0.element["history_message_index"] as? Int ?? rows.count
            let rhs = $1.element["history_message_index"] as? Int ?? rows.count
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }
        let expected = toolImages.compactMap { renderImage($0.element) }.flatMap(MediaSource.markdownImages)
        let expectedPaths = Set(expected)
        let references = allReferences.filter { expectedPaths.contains($0) }
        try check(expected.count == toolImages.count && references == expected && !references.isEmpty, "Every real tool screenshot must survive in order")
        for (path, image) in zip(references, toolImages) {
            guard let encoded = image.element["data"] as? String, let original = Data(base64Encoded: encoded) else {
                throw CheckFailure(message: "Decode original image")
            }
            try check(try Data(contentsOf: URL(filePath: path)) == original, "Every real screenshot must match its original bytes")
        }
        let live = JcodeLiveConversation(renderImage: renderImage)
        live.restore(history)
        try check(shape(live.messages) == shape(messages), "Real snapshot and live restore agree")
        let encoded = try HostCodec.encode(live.messages)
        try check(encoded.count < raw.count / 2, "Do not copy full base64 tool screenshots into companion transcript messages")
        print("Real history: \(references.count) tool images preserved, \(raw.count) input bytes → \(encoded.count) transcript bytes")
    }
}
