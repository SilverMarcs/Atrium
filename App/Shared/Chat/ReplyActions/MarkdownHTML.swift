import Foundation

/// Markdown as HTML, so a copied reply pastes with its formatting into apps
/// that take rich text, such as Slack or Notes. Parsed with Foundation's full
/// Markdown syntax, as the reply view parses it.
nonisolated enum MarkdownHTML {
    static func html(from markdown: String) -> String? {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return nil }
        var html = ""
        // The blocks around the previous run, outermost first.
        var open: [PresentationIntent.IntentType] = []
        for run in parsed.runs {
            let blocks = Array((run.presentationIntent?.components ?? []).reversed())
            let kept = zip(open, blocks).prefix { $0.identity == $1.identity }.count
            html += closingTags(of: open, from: kept)
            for index in blocks.indices.dropFirst(kept) {
                html += openingTag(
                    of: blocks[index],
                    parent: index > 0 ? blocks[index - 1] : nil,
                    child: index + 1 < blocks.count ? blocks[index + 1] : nil)
            }
            open = blocks
            let text = String(parsed[run.range].characters)
            switch blocks.last?.kind {
            // The parser writes a break as a dash of its own, which <hr> replaces.
            case .thematicBreak?: break
            case .codeBlock?: html += escaped(text)
            default: html += inline(text, run)
            }
        }
        html += closingTags(of: open, from: 0)
        return "<meta charset=\"utf-8\">" + html
    }

    /// Closes the blocks from `start` in, innermost first.
    private static func closingTags(of blocks: [PresentationIntent.IntentType], from start: Int) -> String {
        blocks.indices.dropFirst(start).reversed().map { index in
            closingTag(of: blocks[index], parent: index > 0 ? blocks[index - 1] : nil)
        }.joined()
    }

    private static func openingTag(
        of block: PresentationIntent.IntentType, parent: PresentationIntent.IntentType?, child: PresentationIntent.IntentType?
    ) -> String {
        switch block.kind {
        case .paragraph: "<p>"
        case .header(let level): "<h\(level)>"
        case .orderedList:
            if case .listItem(let ordinal)? = child?.kind, ordinal != 1 { "<ol start=\"\(ordinal)\">" } else { "<ol>" }
        case .unorderedList: "<ul>"
        case .listItem: "<li>"
        case .codeBlock: "<pre><code>"
        case .blockQuote: "<blockquote>"
        case .thematicBreak: "<hr>"
        case .table: "<table>"
        case .tableHeaderRow, .tableRow: "<tr>"
        case .tableCell: parent?.kind == .tableHeaderRow ? "<th>" : "<td>"
        @unknown default: ""
        }
    }

    private static func closingTag(of block: PresentationIntent.IntentType, parent: PresentationIntent.IntentType?) -> String {
        switch block.kind {
        case .paragraph: "</p>"
        case .header(let level): "</h\(level)>"
        case .orderedList: "</ol>"
        case .unorderedList: "</ul>"
        case .listItem: "</li>"
        case .codeBlock: "</code></pre>"
        case .blockQuote: "</blockquote>"
        case .thematicBreak: ""
        case .table: "</table>"
        case .tableHeaderRow, .tableRow: "</tr>"
        case .tableCell: parent?.kind == .tableHeaderRow ? "</th>" : "</td>"
        @unknown default: ""
        }
    }

    private static func inline(_ text: String, _ run: AttributedString.Runs.Run) -> String {
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.lineBreak) { return "<br>" }
        if let image = run.imageURL {
            return "<img src=\"\(escaped(image.absoluteString))\" alt=\"\(escaped(text))\">"
        }
        var html = escaped(text)
        if intent.contains(.code) { html = "<code>\(html)</code>" }
        if intent.contains(.strikethrough) { html = "<del>\(html)</del>" }
        if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
        if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
        if let link = run.link { html = "<a href=\"\(escaped(link.absoluteString))\">\(html)</a>" }
        return html
    }

    private static func escaped(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;")
            .replacing(">", with: "&gt;").replacing("\"", with: "&quot;")
    }
}
