import Foundation

public nonisolated enum TranscriptBlock: Codable, Sendable, Hashable, Identifiable {
    /// Markdown written by the user or the agent.
    case text(String, id: String)
    /// A run of consecutive tool calls. Only how many there were is kept, so
    /// long tasks stay small on the wire and in memory.
    case tools(count: Int, id: String)
    /// A page the agent showed with Atrium's `render_html` tool.
    case page(TranscriptPage, id: String)

    public var id: String {
        switch self {
        case .text(_, let id), .tools(_, let id), .page(_, let id): id
        }
    }

    /// The markdown of a text block.
    public var text: String? {
        if case .text(let text, _) = self { text } else { nil }
    }

    /// How many calls a tools block stands for.
    public var toolCount: Int {
        if case .tools(let count, _) = self { count } else { 0 }
    }

    /// The page a page block shows.
    public var page: TranscriptPage? {
        if case .page(let page, _) = self { page } else { nil }
    }

    private enum TextCodingKeys: String, CodingKey {
        case _0 = "text"
        case id
    }

    private enum PageCodingKeys: String, CodingKey {
        case _0 = "page"
        case id
    }
}

public nonisolated extension [TranscriptBlock] {
    /// Counts a tool call into the run it continues, or starts a run after text.
    mutating func appendToolCall(id: String) {
        if case .tools(let count, let runID)? = last {
            self[endIndex - 1] = .tools(count: count + 1, id: runID)
        } else {
            append(.tools(count: 1, id: id))
        }
    }
}
