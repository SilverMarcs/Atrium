import SwiftUI

/// A capsule summarizing a run of tool calls; tapping it lists each call.
struct ToolGroupBadge: View {
    let tools: [TranscriptBlock]
    @State private var showingList = false

    var body: some View {
        Button {
            showingList = true
        } label: {
            HStack(spacing: 6) {
                ForEach(symbols.prefix(4), id: \.self) { symbol in
                    Image(systemName: symbol)
                        .imageScale(.small)
                }
                Text(tools.count == 1 ? "1 tool" : "\(tools.count) tools")
                    .font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background.secondary, in: .capsule)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingList) {
            AssistantStepsSheet(steps: tools)
        }
    }

    /// Each tool's symbol once, in the order the tools first ran.
    private var symbols: [String] {
        var seen = Set<String>()
        return tools.map(\.symbolName).filter { seen.insert($0).inserted }
    }
}
