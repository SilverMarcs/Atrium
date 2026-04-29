import SwiftUI

/// Capsule pill summarising a contiguous run of tool calls. Tap opens a
/// sheet listing each call. Built as a plain `HStack` with `onTapGesture`
/// rather than a `Button` because the `.bordered`/`.borderless` button
/// styles tint the content with accent and don't expose a clean knob to
/// override per-state.
struct ToolGroupBadge: View {
    let tools: [WireBlock]
    @State private var showingList = false

    private var distinctSymbols: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for symbol in tools.compactMap(\.toolSymbolName) where seen.insert(symbol).inserted {
            ordered.append(symbol)
        }
        return ordered
    }

    private var countLabel: String {
        tools.count == 1 ? "1 tool" : "\(tools.count) tools"
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(distinctSymbols.prefix(4), id: \.self) { symbol in
                Image(systemName: symbol)
                    .imageScale(.small)
            }
            Text(countLabel)
                .font(.caption.monospacedDigit())
                // .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.secondary)
        .clipShape(.capsule)
        .contentShape(.capsule)
        .onTapGesture { showingList = true }
        .sheet(isPresented: $showingList) {
            ToolCallListSheet(tools: tools)
        }
    }
}
