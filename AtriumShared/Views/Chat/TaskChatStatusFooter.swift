import SwiftUI

/// Shared optimistic/host state; waiting directs the reader to the appropriate host UI.
struct TaskChatStatusFooter: View {
    let status: AgentThreadStatus

    var body: some View {
        switch status {
        case .processing:
            ProgressView()
                #if os(macOS)
                .controlSize(.small)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
        case .waiting:
            #if os(macOS)
            let message: LocalizedStringKey = "Waiting for your answer in Terminal"
            #else
            let message: LocalizedStringKey = "Waiting for your answer on your host"
            #endif
            Label(message, systemImage: "exclamationmark.bubble")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
        default:
            EmptyView()
        }
    }
}
