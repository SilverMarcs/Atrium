import SwiftUI

struct ChatSidebarRow: View {
    let chat: Chat
    @Environment(AppState.self) private var appState

    @State private var isRenaming = false
    @FocusState private var isNameFieldFocused: Bool

    private var showNotificationBadge: Bool {
        chat.hasNotification && appState.selectedChat?.id != chat.id
    }

    var body: some View {
        Label {
            if isRenaming {
                TextField("Chat Name", text: Bindable(chat).title)
                    .textFieldStyle(.plain)
                    .focused($isNameFieldFocused)
                    .onSubmit { isRenaming = false }
                    .onExitCommand { isRenaming = false }
                    .onAppear { isNameFieldFocused = true }
            } else {
                Text(chat.displayTitle)
                    .lineLimit(1)
            }
        } icon: {
            Image(chat.provider.imageName)
                .foregroundStyle(chat.isActive ? chat.provider.color : .primary)
        }
        .badge(showNotificationBadge ? Text("") : nil)
        .badgeProminence(.increased)
        .contextMenu {
            Button {
                isRenaming = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                chat.disconnect()
            } label: {
                Label("Disconnect", systemImage: "bolt.slash")
            }
            .disabled(!chat.isActive)

            Divider()

            Button {
                if appState.selectedChat?.id == chat.id {
                    appState.selectedChat = nil
                }
                chat.disconnect()
                chat.isArchived = true
            } label: {
                Label("Archive", systemImage: "archivebox")
            }

            Button(role: .destructive) {
                if appState.selectedChat?.id == chat.id {
                    appState.selectedChat = nil
                }
                chat.workspace?.removeChat(chat)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .renameAction {
            isRenaming = true
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                if appState.selectedChat?.id == chat.id {
                    appState.selectedChat = nil
                }
                chat.disconnect()
                chat.isArchived = true
            } label: {
                Label("Archive", systemImage: "archivebox")
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
                chat.workspace?.removeChat(chat)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
        }
    }
}
