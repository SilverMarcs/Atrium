import AtriumClient
import SwiftUI

/// Waits for the default draft's host, project and agent to become available.
struct NewChatUnavailableView: View {
    let showDraft: (TaskRef) -> Void
    @Environment(HostDirectory.self) private var hosts

    var body: some View {
        Group {
            if !hosts.hasLoadedTasks || hosts.canStartNewChat {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "New Chat Unavailable",
                    systemImage: "square.and.pencil",
                    description: Text("Connect to a host with a project and an enabled agent to start a chat.")
                )
            }
        }
        .task(id: hosts.canStartNewChat) {
            if let ref = hosts.prepareNewChat() { showDraft(ref) }
        }
    }
}
