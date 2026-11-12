import AtriumProtocol
import Foundation

/// The small part of a Claude transcript needed by the sidebar, read from
/// bounded head/tail windows and the newest of the records kept up to date
/// from every line Claude appends.
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
    /// How full the conversation keeps Claude's context, as of the newest
    /// reply; unknown once it's compacted, until the next reply.
    let contextTokens: Int?
    /// The folders the session's edit tools changed files in.
    let edits: AgentEdits
    /// The folder its commands last ran in, which a `cd` changes.
    let currentDirectory: String?

    /// The model, reasoning effort and speed of a reply, and the tokens its
    /// request took in unless the conversation was compacted since: all of its
    /// input, cached or not, as Claude's `/context` counts it.
    struct Reply: Equatable, Sendable {
        let model: String
        let effort: String?
        let speed: String?
        var contextTokens: Int?
    }

    /// The newest records of the kinds that can sit anywhere in a transcript.
    /// Before each reply Claude appends a prompt's attachments and request
    /// records, often hundreds of kilobytes, which push the ones before them
    /// out of the tail window, so these are read from every line instead.
    struct Latest: Equatable, Sendable {
        var customTitle: String?
        var firstAITitle: String?
        var aiTitle: String?
        var agentName: String?
        var lastPrompt: String?
        /// The folder the session last moved into, or back to from a worktree.
        var worktreeDirectory: String?
        /// The folder the newest record was written in.
        var cwd: String?
        var edits = AgentEdits()
        var activity: Date?
        var reply: Reply?
    }

    static func parse(head: String, tail: String, renamedTitle: String?, latest: Latest) -> Self? {
        // Claude has used transcript records for names and, more recently, a separate rename file.
        let customName = string("customTitle", in: tail, last: true) ?? renamedTitle ?? latest.customTitle
        let name = customName ?? latest.aiTitle
        guard let title = name ?? latest.lastPrompt.flatMap(promptTitle)
            ?? string("summary", in: tail, last: true) ?? firstPrompt(in: head) else { return nil }
        // A large first prompt can push its cwd beyond the bounded head window.
        let originalDirectory = string("cwd", in: head)
        return Self(
            title: title,
            hasProviderTitle: name != nil,
            isRenamed: customName != nil,
            agentName: latest.agentName,
            directory: latest.worktreeDirectory ?? originalDirectory ?? latest.cwd ?? "",
            projectDirectory: originalDirectory,
            continuedIn: continuation(in: tail),
            lastActivity: latest.activity,
            model: latest.reply?.model,
            reasoningEffort: latest.reply?.effort,
            isFastMode: latest.reply?.speed.map { $0 == "fast" },
            contextTokens: latest.reply?.contextTokens,
            edits: latest.edits,
            currentDirectory: latest.cwd
        )
    }

    /// The newest reply among lines appended to a transcript, read newest
    /// first, or the one before them when they hold none. A compaction among
    /// them makes its context unknown. API errors are recorded as replies from
    /// a placeholder model.
    static func latestReply(after previous: Reply?, appended lines: some Sequence<Data>) -> Reply? {
        var isCompacted = false
        for line in lines where line.range(of: modelKey) != nil || line.range(of: compactBoundary) != nil {
            guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if record["type"] as? String == "system", record["subtype"] as? String == "compact_boundary" {
                isCompacted = true
                continue
            }
            guard record["type"] as? String == "assistant", let message = record["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.hasPrefix("<") else { continue }
            let usage = message["usage"] as? [String: Any]
            let contextTokens = usage.map { usage in
                ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            }
            return Reply(model: model, effort: record["effort"] as? String, speed: usage?["speed"] as? String,
                         contextTokens: isCompacted ? nil : contextTokens)
        }
        var reply = previous
        if isCompacted { reply?.contextTokens = nil }
        return reply
    }

    private static let modelKey = Data(#""model""#.utf8)
    private static let compactBoundary = Data("compact_boundary".utf8)

    /// When the conversation last changed, as of the newest prompt or reply
    /// among lines appended to a transcript, read newest first, or before them
    /// when they hold none. Claude appends bookkeeping records to old
    /// transcripts on resume and reconnect, so the file's modification date
    /// is not when it last changed.
    static func latestActivity(after previous: Date?, appended lines: some Sequence<Data>) -> Date? {
        for line in lines where line.range(of: timestampKey) != nil {
            guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  ["user", "assistant"].contains(record["type"] as? String),
                  let timestamp = record["timestamp"] as? String else { continue }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp) { return date }
        }
        return previous
    }

    private static let timestampKey = Data(#""timestamp""#.utf8)

    /// Reads a JSON string field, even in a nested record or one a read window cuts off.
    /// Decode the string literal itself so quotes, backslashes and Unicode escapes remain intact.
    static func string(_ key: String, in text: String, last: Bool = false) -> String? {
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
                       let value = nonempty(value) { return value }
                    break
                }
            }
        }
        return nil
    }

    /// What a prompt reads as in a title: a delegated task is its request, and
    /// results relayed back from other agents aren't one.
    private static func promptTitle(_ text: String) -> String? {
        guard let relayed = RelayedMessage.relay(in: text) else { return text }
        return relayed.relay.kind == .task ? relayed.body : nil
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
