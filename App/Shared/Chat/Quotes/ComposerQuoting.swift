import SwiftMarkdownView
import SwiftUI

/// Offers Quote for text selected in the agent's replies, and presents the
/// sheet that writes or changes a quote's reply.
struct ComposerQuoting: ViewModifier {
    @Bindable var composer: TaskComposer
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            // An edit doesn't take quotes.
            .markdownSelectionAction(
                "Quote",
                systemImage: "quote.opening",
                isEnabled: isEnabled && composer.messageEdit == nil
            ) { [composer] text in
                composer.quote(text)
            }
            .sheet(item: $composer.editedQuote) { quote in
                ComposerQuoteSheet(quote: quote, isNew: !composer.quotes.contains { $0.id == quote.id }) {
                    composer.save($0)
                }
            }
    }
}

extension View {
    /// Lets text selected in the chat be quoted in the composer.
    func composerQuoting(_ composer: TaskComposer, isEnabled: Bool = true) -> some View {
        modifier(ComposerQuoting(composer: composer, isEnabled: isEnabled))
    }
}
