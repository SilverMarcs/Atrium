import SwiftUI
import SwiftMarkdownView

/// Renders an agent's Markdown natively with TextKit, the same way LynkChat
/// does: syntax-highlighted code blocks with copy buttons, tables, quotes,
/// lists and headings.
struct MarkdownText: View {
    /// Matches LynkChat's default iOS body size so replies read identically.
    #if os(iOS)
    private static let fontSize: CGFloat = 17.5
    #else
    @AppStorage(ChatFontSize.key) private var fontSize = ChatFontSize.default
    #endif

    let text: String

    var body: some View {
        SwiftMarkdownView(text)
            #if os(iOS)
            .markdownFontSize(Self.fontSize)
            #else
            .markdownFontSize(fontSize)
            #endif
            .markdownCodeTheme(light: "atom-one-light", dark: "atom-one-dark")
            .transaction { $0.animation = nil }
    }
}
