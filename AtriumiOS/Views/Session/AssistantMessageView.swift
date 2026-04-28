import SwiftUI

/// Renders an assistant turn as the underlying blocks: contiguous text
/// runs become a single `NativeMarkdownView`; contiguous tool-call runs
/// collapse into one `ToolGroupBadge`. Order is preserved across the run
/// so a "explanation → tools → follow-up text" cadence looks right.
struct AssistantMessageView: View {
    let blocks: [WireBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                switch group {
                case .text(let text):
                    NativeMarkdownView(text: text)
                case .tools(let symbols):
                    ToolGroupBadge(symbols: symbols)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 30)
    }

    /// Collapses adjacent same-kind blocks. Tool runs can't be merged in the
    /// wire because they may be interleaved with text on the host side.
    private var grouped: [Group] {
        var result: [Group] = []
        for block in blocks {
            switch block.kind {
            case .text:
                guard !block.text.isEmpty else { continue }
                if case .text(let prior) = result.last {
                    result[result.count - 1] = .text(prior + block.text)
                } else {
                    result.append(.text(block.text))
                }
            case .toolCall:
                let symbol = block.toolSymbolName ?? "wrench.and.screwdriver"
                if case .tools(var prior) = result.last {
                    prior.append(symbol)
                    result[result.count - 1] = .tools(prior)
                } else {
                    result.append(.tools([symbol]))
                }
            }
        }
        return result
    }

    private enum Group {
        case text(String)
        case tools([String])
    }
}
