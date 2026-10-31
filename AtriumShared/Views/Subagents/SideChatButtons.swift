import AtriumClient
import AtriumProtocol
import SwiftUI

/// Opens a task's side chat, or starts one when it has none, looking the same
/// either way. The side chat opens with `open`, as a delegated session opens.
struct SideChatButton: View {
    let item: HostTask
    let open: (TaskRef) -> Void

    var body: some View {
        Button("Side Chat", systemImage: "plus.bubble") {
            if let sideChat = item.sideChat {
                open(TaskRef(hostID: item.host.id, taskID: sideChat.id))
            } else {
                item.host.startSideChat(about: item.task.id, open: open)
            }
        }
        .disabled(item.sideChat == nil && !item.task.actions.contains(.sideChat))
    }
}

/// Shown in a side chat: starts a new one about the same session, replacing
/// this one once the user confirms.
struct NewSideChatButton: View {
    let sideChat: HostTask
    let open: (TaskRef) -> Void
    @State private var isConfirming = false

    var body: some View {
        Button("New Side Chat", systemImage: "square.and.pencil") { isConfirming = true }
            .disabled(sideChat.parent?.actions.contains(.sideChat) != true)
            .alert("Start a New Side Chat?", isPresented: $isConfirming) {
                Button("New Side Chat") {
                    if let parent = sideChat.parent { sideChat.host.startSideChat(about: parent.id, open: open) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It replaces this side chat, which can’t be opened again.")
            }
    }
}

private extension HostClient {
    /// Starts a side chat about a task, replacing its previous one, and opens it.
    func startSideChat(about taskID: String, open: @escaping (TaskRef) -> Void) {
        Task {
            if case .task(let id) = await perform(.task(id: taskID, action: .startSideChat)) {
                open(TaskRef(hostID: self.id, taskID: id))
            }
        }
    }
}
