import SwiftUI

struct ChatRow: View {
    let chat: WireSessionMeta

    var body: some View {
        HStack {
            Label {
                Text(chat.title.isEmpty ? "New Chat" : chat.title)
                    .lineLimit(1)

                Text("\(chat.turnCount) turns · \(RelativeTimeFormatter.shortRelative(from: chat.date))")
            } icon: {
                ProviderIconView(providerName: chat.providerName, isActive: chat.isActive)
            }

            Spacer()

            if chat.isProcessing {
                ProgressView()
            }
        }
        .badge(chat.hasNotification ? Text("") : nil)
        .badgeProminence(.increased)
    }
}
