import SwiftUI

/// One step in the steps sheet. A note keeps its icon beside its first line
/// rather than the middle of the whole note.
struct AssistantStepRow: View {
    let step: TranscriptBlock
    #if os(macOS)
    @AppStorage(ChatFontSize.key) private var fontSize = ChatFontSize.default
    #endif

    var body: some View {
        Label {
            if let text = step.text {
                MarkdownText(text: text)
                    #if os(macOS)
                    // The Mac label centers its icon on this guide: the first line's
                    // middle, half a system font line height (about 1.2 × its size).
                    .alignmentGuide(VerticalAlignment.center) { $0[.top] + fontSize * 0.6 }
                    #endif
            } else {
                Text(step.stepTitle)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: step.symbolName)
                .foregroundStyle(.secondary)
                #if os(iOS)
                // iOS list rows ignore that guide, but a full-height icon sits at the top.
                .frame(maxHeight: .infinity, alignment: .top)
                #endif
        }
    }
}
