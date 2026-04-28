import SwiftUI

struct MessageBubble: View {
    let message: WireMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleColor)
                        .clipShape(.rect(cornerRadius: 14))
                        .foregroundStyle(message.role == .user ? .white : .primary)
                        .textSelection(.enabled)
                }
                if !message.toolSummaries.isEmpty {
                    ToolSummariesView(summaries: message.toolSummaries)
                }
            }
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var bubbleColor: Color {
        message.role == .user ? Color.accentColor : Color.gray.opacity(0.18)
    }
}
