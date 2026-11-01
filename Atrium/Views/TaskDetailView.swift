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
            .id(item.id)
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
            .navigationTitle(String(title.prefix(50)))
            .navigationSubtitle(subtitle)
            .focusedSceneValue(\.editorPanel, project?.editor)
    }

    /// A side chat is titled by the session it asks about.
    private var title: String {
        task.isSideChat ? item.parent?.title ?? task.title : task.title
    }

    private var subtitle: String {
        if task.isSideChat { return task.title }
        if let parent = item.parent {
            return "Subagent of \(parent.provider.name) · \(parent.title)"
        }
        if task.origin == .chatGPT { return "Started by ChatGPT" }
        let directory = project?.workspace?.directory ?? task.directory
        return item.host.isLocal ? directory : "\(item.host.name) \(directory)"
    }
}
