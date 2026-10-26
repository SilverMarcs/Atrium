import SwiftUI

/// Renders an agent's Markdown: fenced code as scrollable monospaced blocks,
/// headings in bold, and inline styling, links and lists within paragraphs.
struct MarkdownText: View {
    let text: String
    /// Smaller type for secondary text, such as the steps behind a reply.
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
            ForEach(MarkdownSegment.segments(in: text)) { segment in
                switch segment.kind {
                case .code:
                    ScrollView(.horizontal) {
                        Text(segment.text)
                            .font(isCompact ? .caption.monospaced() : .callout.monospaced())
                            .textSelection(.enabled)
                            .padding(isCompact ? 8 : 10)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: .rect(cornerRadius: 10))
                case .heading:
                    Text(Self.inline(segment.text))
                        .font(isCompact ? .subheadline.bold() : .headline)
                case .paragraph:
                    Text(Self.inline(segment.text))
                        .font(isCompact ? .subheadline : .body)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
