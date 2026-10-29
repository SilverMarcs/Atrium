import SwiftUI

struct AssistantStepRow: View {
    let step: TranscriptBlock

    var body: some View {
        Label {
            Text(step.text ?? TranscriptBlock.toolCalls(step.toolCount))
                .foregroundStyle(step.text == nil ? .secondary : .primary)
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
