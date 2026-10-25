import SwiftUI

struct ThreadListRows: View {
    @Environment(TaskSessionController.self) private var sessions
    @Environment(\.undoManager) private var undoManager
    let threads: [AgentThread]
    let requestDeletion: (AgentThread) -> Void
    let requestRename: (AgentThread) -> Void

    var body: some View {
        ForEach(threads) { thread in
            let state = sessions.menuState(for: thread)
            ThreadRowView(thread: thread)
                .tag(thread.id)
                .contextMenu {
                    TaskContextMenu(state: state) { perform($0, on: thread) }
                }
                .taskSwipeActions(state) { perform($0, on: thread) }
        }
    }

    private func perform(_ action: TaskMenuAction, on thread: AgentThread) {
        switch action {
        case .rename: requestRename(thread)
        case .delete: requestDeletion(thread)
        default: sessions.perform(action, on: thread, undoManager: undoManager)
        }
    }
}
