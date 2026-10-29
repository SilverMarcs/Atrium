import SwiftUI

/// The folded work behind a reply: how many tool calls it took. Opens every step
/// in order, updating while the agent still works.
struct AssistantStepsButton: View {
    let steps: [TranscriptBlock]
    @State private var showingSteps = false

    var body: some View {
        Button {
            showingSteps = true
        } label: {
            HStack(spacing: 6) {
                ForEach(symbols.prefix(4), id: \.self) { symbol in
                    Image(systemName: symbol)
                        .imageScale(.small)
                }
                Text(label)
                    .font(.caption.monospacedDigit())
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background.secondary, in: .capsule)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingSteps) {
            AssistantStepsSheet(steps: steps)
        }
    }

    /// Notes folded before any tool call has run are counted instead.
    private var label: String {
        let toolCount = steps.reduce(0) { $0 + $1.toolCount }
        guard toolCount == 0 else { return TranscriptBlock.toolCalls(toolCount) }
        return steps.count == 1 ? "1 note" : "\(steps.count) notes"
    }

    /// Each kind of step once, in the order it first happened.
    private var symbols: [String] {
        var seen = Set<String>()
        return steps.map(\.symbolName).filter { seen.insert($0).inserted }
    }
}
