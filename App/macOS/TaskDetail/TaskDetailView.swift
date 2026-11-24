import SwiftUI

/// A task's chat, on this Mac or a paired host.
struct TaskDetailView: View {
    let item: HostTask
    @Environment(AppModel.self) private var app

    private var task: WireTask { item.task }

    var body: some View {
        SessionChatView(item: item, project: app.project(for: item))
            // A new chat's task keeps its draft's timeline once the host creates it.
            .id(app.hosts.screenID(for: item.id))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: task.hasUnreadResult) {
                // Viewing a finished task reads it, on whichever host it's on.
                if task.hasUnreadResult { item.host.send(.task(id: task.id, action: .viewed)) }
            }
            .toolbar {
                TaskDetailToolbar(item: item)
            }
            .navigationTitle(app.hosts.navigationTitle(for: item))
            .modifier(ConnectionStatusSubtitle(
                hosts: [item.host],
                subtitle: app.hosts.navigationSubtitle(for: item)
            ))
    }
}
