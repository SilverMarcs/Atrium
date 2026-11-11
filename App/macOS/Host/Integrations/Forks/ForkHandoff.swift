import AtriumProtocol
import Foundation

/// How a chat forked into the other provider gives that provider's agent the
/// conversation so far. It goes ahead of the fork's first prompt: a prompt is
/// how both providers take in context, and neither has a way to take a
/// conversation they didn't hold before a turn.
///
/// The conversation is the one the chat showed, as text: what the user and the
/// agent wrote, with tool calls counted but not shown. Atrium finds the handoff
/// in the fork's history and shows only the prompt that follows it.
nonisolated enum ForkHandoff {
    static let tag = "atrium-handoff"

    /// The share of the new agent's context window the conversation may take,
    /// leaving the rest for its instructions, its tools and the work that
    /// follows, so the first turn neither overflows the window nor sets off
    /// the provider's compaction. It also absorbs `estimatedTokens` running
    /// low, as it does for text that tokenizes densely.
    static let windowShare = 0.5

    /// The window taken for a model whose provider doesn't report one, smaller
    /// than either provider's current models.
    static let assumedContextWindow = 128_000

    /// The conversation's newest messages that fit in `tokens`, as the
    /// handoff to put ahead of the fork's first prompt. Whole messages are
    /// taken, newest first, except that a newest message too long by itself
    /// is cut to its end. Nil for a conversation with nothing to hand over.
    static func text(of messages: [TranscriptMessage], from provider: AgentProvider, fittingIn tokens: Int) -> String? {
        let entries = messages.compactMap { entry(for: $0, agent: provider.name) }
        guard !entries.isEmpty else { return nil }
        var kept: [String] = []
        var isPartial = false
        var remaining = tokens - estimatedTokens(preamble(from: provider, isPartial: true))
        for entry in entries.reversed() {
            let cost = estimatedTokens(entry.text)
            guard cost <= remaining else {
                if kept.isEmpty, remaining > 0 { kept = [entry.cut(toLast: remaining * 3)] }
                isPartial = true
                break
            }
            kept.insert(entry.text, at: 0)
            remaining -= cost
        }
        guard !kept.isEmpty else { return nil }
        return "<\(tag) from=\"\(provider.name)\">\n" + preamble(from: provider, isPartial: isPartial) + "\n\n"
            + kept.joined(separator: "\n\n") + "\n</\(tag)>"
    }

    /// A prompt with the handoff ahead of it.
    static func prompt(_ text: String, after handoff: String) -> String {
        text.isEmpty ? handoff : handoff + "\n\n" + text
    }

    /// The prompt that follows a handoff, for showing it as the user wrote it.
    /// Nil for a prompt without one.
    static func request(in text: String) -> String? {
        guard text.hasPrefix("<\(tag) "), let end = text.range(of: "\n</\(tag)>") else { return nil }
        return text[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tokens the text takes, overestimated for most text: tokenizers average
    /// three to four bytes a token for English and code.
    static func estimatedTokens(_ text: String) -> Int {
        text.utf8.count / 3
    }

    private static func preamble(from provider: AgentProvider, isPartial: Bool) -> String {
        let name = provider.name
        return "This chat is a fork, made in Atrium, of the user's conversation with \(name). "
            + "Its most recent part follows, oldest first and as the user saw it: what they and \(name) wrote, with tool calls counted but not shown. "
            + (isPartial ? "Earlier messages were left out to fit. " : "")
            + "Continue the conversation from there with the user's message that comes after it, checking the workspace for what earlier tool calls did. "
            + "Your usual instructions and approval rules still apply."
    }

    private struct Entry {
        let header: String
        let body: String
        var text: String { header + "\n" + body + "\n</message>" }

        /// The entry with its body cut to about its last `bytes`.
        func cut(toLast bytes: Int) -> String {
            header + "\n[…]" + String(decoding: body.utf8.suffix(max(bytes, 0)), as: UTF8.self) + "\n</message>"
        }
    }

    private static func entry(for message: TranscriptMessage, agent: String) -> Entry? {
        var lines: [String] = []
        for block in message.blocks {
            switch block {
            case .text(let text, _): lines.append(text)
            case .tools(let count, _): lines.append(count == 1 ? "[1 tool call]" : "[\(count) tool calls]")
            case .page(let page, _): lines.append("[Showed a page: \(page.title)]")
            case .report(let sender, _): lines.append("[\(sender.name) reported back]")
            }
        }
        if let count = message.images?.count, count > 0 {
            lines.append(count == 1 ? "[1 image attached]" : "[\(count) images attached]")
        }
        let body = lines.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing("</\(tag)", with: "<\\/\(tag)")
        guard !body.isEmpty else { return nil }
        let from = switch message.role {
        case .assistant: agent
        case .user: message.relay.map { $0.senders.map(\.name).joined(separator: ", ") } ?? "user"
        }
        return Entry(header: "<message from=\"\(from)\">", body: body)
    }
}
