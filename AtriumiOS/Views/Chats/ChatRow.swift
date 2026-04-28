import SwiftUI

struct ChatRow: View {
    let chat: WireSessionMeta

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.title.isEmpty ? "New Chat" : chat.title)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if chat.turnCount > 0 {
                            Text("\(chat.turnCount) turns")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Text(ShortRelativeDate.string(from: chat.date))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } icon: {
                ProviderIconView(providerName: chat.providerName, isActive: chat.isActive)
            }

            Spacer()

            if chat.isProcessing {
                ProgressView().controlSize(.small)
            } else if chat.isActive {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            }
        }
        .badge(chat.hasNotification ? Text("") : nil)
        .badgeProminence(.increased)
    }
}
