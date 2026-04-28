import SwiftUI

struct ToolSummariesView: View {
    let summaries: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(summaries, id: \.self) { summary in
                Text(summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}
