import AtriumProtocol
import SwiftUI

/// The sidebar's trailing indicator: a spinner while the agent works, a
/// symbol for what it's waiting on when it needs input, a blue dot for a
/// result not yet read.
struct TaskStatusIndicator: View {
    let status: AgentThreadStatus
    let hasUnreadResult: Bool
    let isSettled: Bool
    /// The request it's waiting on, when it says, which picks the symbol.
    var waitingOn: AgentInteraction? = nil

    var body: some View {
        if !isSettled {
            if status == .processing {
                ProgressView()
                    .accessibilityLabel("Processing")
            } else if status == .waiting {
                if let waitingOn {
                    let kind = waitingOn.kind
                    Image(systemName: kind.symbolName)
                        .font(.caption)
                        .foregroundStyle(kind.color)
                        .accessibilityLabel(kind.waitingLabel)
                        .help(waitingOn.title)
                } else {
                    Text("●")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Needs input")
                }
            } else if hasUnreadResult {
                Text("●")
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Unread result")
            }
        }
    }
}
