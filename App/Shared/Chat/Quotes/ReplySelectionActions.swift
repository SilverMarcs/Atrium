import SwiftMarkdownView
import SwiftUI

/// Offers Quote and Scratchpad for text selected in the agent's replies, and
/// presents the sheet that writes or changes a quote's reply. A subagent
/// answers only to its own agent, so it offers neither.
struct ReplySelectionActions: ViewModifier {
    @Bindable var composer: TaskComposer
    let item: HostTask?

    private var isEnabled: Bool { item?.task.isSubagent != true }

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .markdownSelectionPopover()
            #endif
            // An edit doesn't take quotes.
            .markdownSelectionAction(
                "Quote",
                systemImage: "quote.opening",
                isEnabled: isEnabled && composer.messageEdit == nil
            ) { [composer] text in
                composer.quote(text)
            }
            // Only a project's chats have a scratchpad.
            .markdownSelectionAction(
                "Scratchpad",
                systemImage: "note.text",
                isEnabled: isEnabled && item?.task.workspaceID != nil
            ) { [composer, item] text in
                if let item { composer.addTextToScratchpad(text, of: item) }
            }
            .sheet(item: $composer.editedQuote) { quote in
                ComposerQuoteSheet(quote: quote, isNew: !composer.quotes.contains { $0.id == quote.id }) {
                    composer.save($0)
                }
            }
    }
}

extension View {
    /// Lets text selected in the chat be quoted in the composer or put aside
    /// in the project's scratchpad.
    func replySelectionActions(_ composer: TaskComposer, item: HostTask?) -> some View {
        modifier(ReplySelectionActions(composer: composer, item: item))
    }
}
