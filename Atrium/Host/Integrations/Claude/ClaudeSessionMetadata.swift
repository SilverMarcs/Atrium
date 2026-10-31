import AtriumProtocol
import Foundation

/// The small part of a Claude transcript needed by the sidebar, read from bounded head/tail windows.
nonisolated struct ClaudeSessionMetadata: Sendable {
    var title: String
    let hasProviderTitle: Bool
    /// Whether the title is a name someone gave the session rather than one Claude generated.
    let isRenamed: Bool
    /// The name Claude gives a background session, which also replaces its readable title.
    let agentName: String?
    let directory: String
    let projectDirectory: String?
    let continuedIn: String?
    let lastActivity: Date?
    let model: String?
    let reasoningEffort: String?
    let isFastMode: Bool?

    /// `earlierCustomTitle` is the latest rename recorded anywhere in the transcript, which can be outside both windows.
    static func parse(head: String, tail: String, renamedTitle: String?, earlierCustomTitle: String?) -> Self? {
        // Claude has used transcript records for names and, more recently, a separate rename file.
        let customName = string("customTitle", in: tail, last: true) ?? renamedTitle ?? earlierCustomTitle
        let name = customName ?? string("aiTitle", in: tail, last: true) ?? string("aiTitle", in: head, last: true)
        guard let title = name ?? string("lastPrompt", in: tail, last: true).flatMap(promptTitle)
            ?? string("summary", in: tail, last: true) ?? firstPrompt(in: head) else { return nil }
        // A large first prompt can push its cwd beyond the bounded head window.
        let originalDirectory = string("cwd", in: head)
        let reply = latestReply(in: tail)
        return Self(
            title: title,
            hasProviderTitle: name != nil,
            isRenamed: customName != nil,
            agentName: string("agentName", in: tail, last: true) ?? string("agentName", in: head, last: true),
            directory: worktreeDirectory(in: tail) ?? originalDirectory
                ?? string("cwd", in: tail, last: true) ?? "",
            projectDirectory: originalDirectory,
            continuedIn: continuation(in: tail),
            lastActivity: lastActivity(in: tail),
            model: reply?.model,
            reasoningEffort: reply?.effort,
            isFastMode: reply?.speed.map { $0 == "fast" }
        )
    }

    /// The model, reasoning effort and speed of the newest reply. API errors are
    /// recorded as replies from a placeholder model.
    private static func latestReply(in tail: String) -> (model: String, effort: String?, speed: String?)? {
        for line in tail.split(separator: "\n").reversed() where line.contains("\"model\"") {
            guard let record = object(line), record["type"] as? String == "assistant",
                  let message = record["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.hasPrefix("<") else { continue }
            let usage = message["usage"] as? [String: Any]
            return (model, record["effort"] as? String, usage?["speed"] as? String)
        }
        return nil
    }

    /// Claude appends bookkeeping records to old transcripts on resume and reconnect,
    /// so the file's modification date is not when the conversation last changed.
    private static func lastActivity(in tail: String) -> Date? {
        for line in tail.split(separator: "\n").reversed() where line.contains("\"timestamp\"") {
            guard let record = object(line), ["user", "assistant"].contains(record["type"] as? String),
                  let timestamp = record["timestamp"] as? String else { continue }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp) { return date }
        }
        return nil
    }

    /// Where the session works after moving into or out of a worktree, whichever
    /// it did last: Claude records the folder it moved into, and the one leaving
    /// a worktree restored. Recording a return is not guaranteed, so a later
    /// exit still wins over an earlier move.
    private static func worktreeDirectory(in tail: String) -> String? {
        [field("relocatedCwd", in: tail, last: true), field("restoredCwd", in: tail, last: true)]
            .compactMap(\.self)
            .max { $0.location < $1.location }?
            .value
    }

    private static func string(_ key: String, in text: String, last: Bool = false) -> String? {
        field(key, in: text, last: last)?.value
    }

    /// Reads a JSON string field even when a large record crosses the edge of a read window.
    /// Decode the string literal itself so quotes, backslashes and Unicode escapes remain intact.
    private static func field(_ key: String, in text: String, last: Bool) -> (value: String, location: String.Index)? {
        var remaining = text.startIndex..<text.endIndex
        while let match = text.range(of: "\"\(key)\"", options: last ? .backwards : [], range: remaining) {
            if last { remaining = remaining.lowerBound..<match.lowerBound }
            else { remaining = match.upperBound..<remaining.upperBound }
            var suffix = text[match.upperBound...].drop(while: \.isWhitespace)
            guard suffix.first == ":" else { continue }
            suffix = suffix.dropFirst().drop(while: \.isWhitespace)
            guard suffix.first == "\"" else { continue }
            var escaped = false
            for index in suffix.indices.dropFirst() {
                let character = suffix[index]
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "\"" {
                    let data = Data(suffix[...index].utf8)
                    if let value = try? JSONDecoder().decode(String.self, from: data),
                       let value = nonempty(value) { return (value, match.lowerBound) }
                    break
                }
            }
        }
        return nil
    }

    /// What a prompt reads as in a title: a delegated task is its request, and
    /// results relayed back from other agents aren't one.
    private static func promptTitle(_ text: String) -> String? {
        if let relayed = RelayedMessage.relay(in: text), relayed.relay.kind == .task { return relayed.body }
        return RelayedMessage.isRelayed(text) ? nil : text
    }

    private static func firstPrompt(in head: String) -> String? {
        var fallback: String?
        for line in head.split(separator: "\n") where line.contains("\"user\"") {
            guard let record = object(line), record["type"] as? String == "user",
                  record["isMeta"] as? Bool != true, record["isCompactSummary"] as? Bool != true,
                  let message = record["message"] as? [String: Any] else { continue }
            let content = message["content"]
            let blocks = content as? [[String: Any]] ?? []
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { continue }
            let texts = (content as? String).map { [$0] }
                ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            for text in texts {
                guard let text = promptTitle(text).flatMap({ nonempty($0.replacing("\n", with: " ")) }) else { continue }
                if let command = tag("command-name", in: text) { fallback = fallback ?? command; continue }
                if let command = tag("bash-input", in: text) { return "! \(command)" }
                if ["<local-command-", "<command-message>", "<task-notification>", "<system-reminder>"].contains(where: text.hasPrefix) {
                    continue
                }
                return text.count > 200 ? String(text.prefix(200)) + "…" : text
            }
            if blocks.contains(where: { $0["type"] as? String == "image" }) { fallback = fallback ?? "Image" }
            if blocks.contains(where: { $0["type"] as? String == "document" }) { fallback = fallback ?? "Document" }
        }
        return fallback
    }

    private static func continuation(in tail: String) -> String? {
        guard tail.contains("\"continued-in\"") else { return nil }
        for line in tail.split(separator: "\n").reversed() {
            guard let record = object(line), let type = record["type"] as? String else { continue }
            if type == "continued-in" { return record["continuedInSessionId"] as? String }
            if type == "user" { return nil }
            if type == "assistant", record["isApiErrorMessage"] as? Bool != true,
               let message = record["message"] as? [String: Any], message["stop_reason"] is String { return nil }
        }
        return nil
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"),
              let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
        return nonempty(String(text[start.upperBound..<end.lowerBound]))
    }

    private static func nonempty(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func object(_ line: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}
