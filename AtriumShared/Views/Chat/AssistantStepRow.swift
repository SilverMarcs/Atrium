import SwiftUI

struct AssistantStepRow: View {
    let step: TranscriptBlock

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                if step.kind == .tool {
                    Text(step.toolName ?? "Tool")
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.primary)
                    Text(step.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(step.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .padding(.vertical, 2)
                }
            }
            #if os(macOS)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            #endif
        } icon: {
            Image(systemName: step.kind == .text ? "text.alignleft" : step.symbolName)
                .foregroundStyle(.secondary)
        }
    }
}
