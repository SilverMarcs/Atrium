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

    private var usageString: String {
        guard used > 0 else { return "—" }
        if total > 0 {
            return "\(TokenFormatter.format(used)) / \(TokenFormatter.format(total))"
        }
        return TokenFormatter.format(used)
    }

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(used) / Double(total))
    }
}
