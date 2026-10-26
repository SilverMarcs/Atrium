import SwiftUI

/// The folded work behind a reply: how many steps it took and the kinds of tools
/// it used. Opens every step in order.
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
                Text(steps.count == 1 ? "1 step" : "\(steps.count) steps")
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

    /// Each kind of step once, in the order it first happened.
    private var symbols: [String] {
        var seen = Set<String>()
        return steps.map { $0.kind == .text ? "text.alignleft" : $0.symbolName }.filter { seen.insert($0).inserted }
    }
}
