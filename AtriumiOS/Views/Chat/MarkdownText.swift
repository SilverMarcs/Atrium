import SwiftUI
import SwiftMarkdownView

/// Renders an agent's Markdown natively with TextKit, the same way LynkChat
/// does: syntax-highlighted code blocks with copy buttons, tables, quotes,
/// lists and headings.
struct MarkdownText: View {
    /// Matches LynkChat's default iOS body size so replies read identically.
    private static let fontSize: CGFloat = 17.5

    let text: String

    var body: some View {
        SwiftMarkdownView(text)
            .markdownFontSize(Self.fontSize)
            .markdownCodeTheme(light: "atom-one-light", dark: "atom-one-dark")
            .transaction { $0.animation = nil }
    }
}
