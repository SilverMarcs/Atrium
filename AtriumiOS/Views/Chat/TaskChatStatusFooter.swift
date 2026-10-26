import SwiftUI

/// What the agent is doing now: working, or waiting for an answer only the host can give.
struct TaskChatStatusFooter: View {
    let status: AgentThreadStatus

    var body: some View {
        switch status {
        case .processing:
            // Where the agent's reply will appear.
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)
        case .waiting:
            Label("Waiting for your answer on your host", systemImage: "exclamationmark.bubble")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
        default:
            EmptyView()
        }
    }
}
