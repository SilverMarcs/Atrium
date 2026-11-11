import AtriumProtocol
import SwiftUI

/// Keep active-turn geometry stable while questions or approvals wait in a sheet.
struct TaskChatStatusFooter: View {
    let status: AgentThreadStatus

    var body: some View {
        switch status {
        case .processing, .waiting:
            ProgressView()
                #if os(macOS)
                .controlSize(.small)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }
}
