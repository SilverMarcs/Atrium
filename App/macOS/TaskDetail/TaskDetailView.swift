import AtriumClient
import AtriumProtocol
import SwiftUI

/// A task's chat, on this Mac or a paired host, above its editor.
struct TaskDetailView: View {
    let item: HostTask
    @Environment(AppModel.self) private var app
    @State private var showingScratchPad = false

    private var task: WireTask { item.task }
    private var project: Project? {
        task.workspaceID.flatMap { app.project(WorkspaceRef(hostID: item.host.id, workspaceID: $0)) }
    }

    var body: some View {
        SessionChatView(item: item, project: project)
            // A new chat's task keeps its draft's timeline once the host creates it.
            .id(app.hosts.screenID(for: item.id))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: task.hasUnreadResult) {
                // Viewing a finished task reads it, on whichever host it's on.
                if task.hasUnreadResult { item.host.send(.task(id: task.id, action: .viewed)) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let project {
                    BottomSheetView(project: project)
                }
            }
            .toolbar {
                TaskDetailToolbar(item: item, showingScratchPad: $showingScratchPad)
            }
            .sheet(isPresented: $showingScratchPad) {
                if let workspaceID = task.workspaceID {
                    ScratchPadSheet(host: item.host, workspaceID: workspaceID)
                }
            }
            .navigationTitle(app.hosts.navigationTitle(for: item))
            .modifier(ConnectionStatusSubtitle(
                hosts: [item.host],
                subtitle: app.hosts.navigationSubtitle(for: item)
            ))
            .focusedSceneValue(\.editorPanel, project?.editor)
    }
}
