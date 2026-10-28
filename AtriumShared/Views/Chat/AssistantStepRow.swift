import SwiftUI

struct AssistantStepRow: View {
    let step: TranscriptBlock

    var body: some View {
        Label {
            Text(step.text ?? TranscriptBlock.toolCalls(step.toolCount))
                .font(.subheadline)
                .foregroundStyle(step.text == nil ? .secondary : .primary)
                .padding(.vertical, 2)
                #if os(macOS)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                #endif
        } icon: {
            Image(systemName: step.symbolName)
                .foregroundStyle(.secondary)
        }
    }
}
