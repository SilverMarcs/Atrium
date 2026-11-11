import AtriumProtocol
import SwiftUI

/// A capsule counting a run of tool calls while the agent works.
struct ToolGroupBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .imageScale(.small)
            Text(TranscriptBlock.toolCalls(count))
                .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.secondary, in: .capsule)
    }
}
