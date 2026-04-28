import SwiftUI

/// Compact summary of a contiguous run of tool calls in an assistant
/// message: distinct tool icons (deduped, capped) plus a count. No
/// per-call detail — the iOS view stays a viewer, not a control surface.
struct ToolGroupBadge: View {
    let symbols: [String]

    private var distinctSymbols: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for symbol in symbols where seen.insert(symbol).inserted {
            ordered.append(symbol)
        }
        return ordered
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(distinctSymbols.prefix(4), id: \.self) { symbol in
                Image(systemName: symbol)
                    .imageScale(.small)
            }
            Text(countLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.secondary)
        .clipShape(.capsule)
    }

    private var countLabel: String {
        symbols.count == 1 ? "1 tool" : "\(symbols.count) tools"
    }
}
