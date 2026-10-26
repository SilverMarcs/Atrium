import SwiftUI

/// What the agent is doing now: working, or waiting for an answer only the Mac can give.
struct TaskChatStatusFooter: View {
    let status: AgentThreadStatus

    var body: some View {
        switch status {
        case .processing:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .waiting:
            Label("Waiting for your answer on your Mac", systemImage: "exclamationmark.bubble")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
        default:
            EmptyView()
        }
    }
}
