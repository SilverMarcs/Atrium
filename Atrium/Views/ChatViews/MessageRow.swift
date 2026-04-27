import SwiftUI

struct MessageRow: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .user:
            UserMessageView(message: message)
        case .assistant:
            AssistantMessageView(message: message)
        }
    }
}
