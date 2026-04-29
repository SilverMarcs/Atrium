import SwiftUI

struct ContextUsageRow: View {
    let used: Int
    let total: Int

    var body: some View {
        LabeledContent {
            if total > 0 {
                CircularProgressDial(progress: progress)
                    .frame(width: 22, height: 22)
            }
        } label: {
            Text(usageString)
                .font(.body.monospacedDigit())
        }
    }

    /// Same format as the macOS navigation subtitle on the chat view —
    /// "12.3K / 200K" or just "320" for very small contexts.
    private var usageString: String {
        guard used > 0 else { return "—" }
        if total > 0 {
            return "\(formatTokens(used)) / \(formatTokens(total))"
        }
        return formatTokens(used)
    }

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(used) / Double(total))
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
