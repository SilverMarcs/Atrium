import AtriumProtocol
import SwiftUI

/// The sidebar's trailing indicator: a spinner while the agent works, an
/// orange dot when it needs input, a blue dot for a result not yet read.
struct TaskStatusIndicator: View {
    let status: AgentThreadStatus
    let hasUnreadResult: Bool
    let isSettled: Bool

    var body: some View {
        if !isSettled {
            if status == .processing {
                ProgressView()
                    .accessibilityLabel("Processing")
            } else if status == .waiting {
                Text("●")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Needs input")
            } else if hasUnreadResult {
                Text("●")
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Unread result")
            }
        }
    }
}
