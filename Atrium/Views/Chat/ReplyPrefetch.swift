import AtriumProtocol
import SwiftMarkdownView
import SwiftUI

/// Lays the timeline's finished replies out off the main thread ahead of
/// time, newest first, so a reply scrolling into view for the first time
/// doesn't typeset its Markdown on the main thread. A streaming reply is left
/// out until it finishes, since its text keeps changing.
struct ReplyPrefetch: ViewModifier {
  let rows: [ConversationRow]
  let liveIDs: Set<String>
  @State private var texts: [String] = []

  func body(content: Content) -> some View {
    let finished = rows.reversed().map(\.message).filter { $0.role == .assistant && !liveIDs.contains($0.id) }
    content
      .markdownPrefetch(texts)
      .onChange(of: finished, initial: true) {
        texts = finished.compactMap { AssistantReply(blocks: $0.blocks, isStreaming: false).text }
      }
  }
}
