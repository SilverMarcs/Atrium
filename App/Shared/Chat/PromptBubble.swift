import AtriumProtocol
import SwiftUI

/// A prompt's text in its bubble. A prompt another agent wrote is gray rather
/// than tinted, so the user's own stand out. Both platforms fly a copy of it in
/// when it's sent.
struct PromptBubble: View {
    let text: String
    var questionAnswers: [TranscriptQuestionAnswer]?
    var isFromAgent = false
    /// The app's accent, which an off-screen render doesn't pick up by itself.
    var accent: Color = .accentColor

    var body: some View {
        Group {
            if let questionAnswers, !questionAnswers.isEmpty {
                VStack(alignment: .leading) {
                    ForEach(questionAnswers.enumerated(), id: \.offset) { _, item in
                        VStack(alignment: .leading) {
                            Text(item.question)
                                .foregroundStyle(.secondary)
                            Text(item.answer)
                                .bold()
                        }
                    }
                }
                .textSelection(.enabled)
            } else {
                ExpandableText(text: text)
            }
        }
            #if os(macOS)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            #else
            .padding(12)
            #endif
            .background(isFromAgent ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(accent.quinary))
            .clipShape(.rect(cornerRadius: 20))
    }
}
