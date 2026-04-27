import SwiftUI

struct ChatBrowserRow: View {
    let chat: Chat
    let workspace: Workspace

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            appState.selectedChat = chat
            dismiss()
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(chat.displayTitle)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            if chat.turnCount > 0 {
                                Text("\(chat.turnCount) turns")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Text(ChatBrowserView.shortRelative(from: chat.date))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } icon: {
                    Image(chat.provider.imageName)
                        .foregroundStyle(
                            chat.isActive ? chat.provider.color : .secondary
                        )
                }

                Spacer()

                if chat.session.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else if chat.isActive {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if chat.isActive {
                Button {
                    chat.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
            }

            Button {
                if !chat.isArchived {
                    chat.disconnect()
                }
                chat.isArchived.toggle()
            } label: {
                Label(
                    chat.isArchived ? "Unarchive" : "Archive",
                    systemImage: chat.isArchived ? "tray.and.arrow.up" : "archivebox"
                )
            }

            Button(role: .destructive) {
                if appState.selectedChat?.id == chat.id {
                    appState.selectedChat = nil
                }
                workspace.removeChat(chat)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                if !chat.isArchived {
                    if appState.selectedChat?.id == chat.id {
                        appState.selectedChat = nil
                    }
                    chat.disconnect()
                }
                chat.isArchived.toggle()
            } label: {
                Label(
                    chat.isArchived ? "Unarchive" : "Archive",
                    systemImage: chat.isArchived ? "tray.and.arrow.up" : "archivebox"
                )
            }
            .labelStyle(.iconOnly)
            .tint(.orange)

            if chat.isActive {
                Button {
                    chat.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
                .labelStyle(.iconOnly)
                .tint(.gray)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                if appState.selectedChat?.id == chat.id {
                    appState.selectedChat = nil
                }
                workspace.removeChat(chat)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
        }
    }
}
