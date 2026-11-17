import Foundation

/// A passage of the chat quoted in the draft, with the user's reply to it.
/// It's sent as a Markdown quote ahead of the draft.
nonisolated struct ComposerQuote: Identifiable, Hashable {
    let id = UUID()
    let text: String
    var reply = ""

    /// The passage as a Markdown quote, followed by the reply.
    var markdown: String {
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.allSatisfy(\.isWhitespace) ? ">" : "> \($0)" }
            .joined(separator: "\n")
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? quoted : "\(quoted)\n\n\(reply)"
    }

    /// The prompt for `draft`, with `quotes` ahead of it.
    static func prompt(quoting quotes: [ComposerQuote], draft: String) -> String {
        (quotes.map(\.markdown) + [draft.trimmingCharacters(in: .whitespacesAndNewlines)])
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
