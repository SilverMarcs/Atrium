import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Shared prompt bubble; only expansion, desktop copy, and the mobile flight differ.
struct UserMessageView: View {
    let text: String
    var images: [Data] = []
    var sendFlight: (PromptSendAnimator) -> PromptSendFlight? = { _ in nil }

    var body: some View {
        VStack(alignment: .trailing) {
            if !images.isEmpty {
                HStack {
                    ForEach(images.enumerated(), id: \.offset) { _, data in PromptImageThumbnail(data: data) }
                }
            }
            if !text.isEmpty {
            #if os(macOS)
            ExpandableText(text: text)
            #else
            Text(text)
            #endif
            }
        }
        .padding(12)
        // .background(.background.secondary)
        .background(Color.accentColor.quinary)
        .clipShape(.rect(cornerRadius: 20))
        .modifier(PromptSendEffect(flight: sendFlight))
        .frame(maxWidth: .infinity, alignment: .trailing)
        #if os(macOS)
        .contextMenu {
            Button("Copy Message", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        .padding(.leading, 160)
        #else
        .padding(.leading, 60)
        #endif
        .textSelection(.enabled)
    }
}
