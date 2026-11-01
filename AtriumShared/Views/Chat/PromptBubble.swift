import SwiftUI

/// A prompt's text in its bubble. A prompt another agent wrote is gray rather
/// than tinted, so the user's own stand out. The Mac flies a copy of it in
/// when it's sent.
struct PromptBubble: View {
    let text: String
    var isFromAgent = false

    var body: some View {
        ExpandableText(text: text)
            #if os(macOS)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            #else
            .padding(12)
            #endif
            .background(isFromAgent ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(Color.accentColor.quinary))
            .clipShape(.rect(cornerRadius: 20))
    }
}
