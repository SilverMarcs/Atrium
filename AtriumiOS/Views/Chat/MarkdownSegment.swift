import Foundation

/// A block of Markdown: a fenced code block, a heading, or a paragraph (which
/// may hold list items and keeps its line breaks).
struct MarkdownSegment: Identifiable {
    enum Kind {
        case paragraph
        case heading
        case code
    }

    let id: Int
    let kind: Kind
    let text: String

    static func segments(in markdown: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var paragraph: [String] = []
        var code: [String]?

        func append(_ kind: Kind, _ text: String) {
            segments.append(MarkdownSegment(id: segments.count, kind: kind, text: text))
        }
        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { append(.paragraph, text) }
            paragraph = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    append(.code, lines.joined(separator: "\n"))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if line.hasPrefix("#") {
                flushParagraph()
                append(.heading, line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
                paragraph.append(isBullet ? "• " + trimmed.dropFirst(2) : line)
            }
        }
        if let code { append(.code, code.joined(separator: "\n")) }
        flushParagraph()
        return segments
    }
}
