import SwiftUI

/// The shared rename and delete prompts, sending the result to the host.
struct TaskConfirmations: ViewModifier {
    @Environment(CompanionClient.self) private var client
    @Binding var taskToRename: WireTask?
    @Binding var taskToDelete: WireTask?

    func body(content: Content) -> some View {
        content.taskConfirmationAlerts(
            renaming: $taskToRename,
            deleting: $taskToDelete,
            currentTitle: \.title,
            deletionMessage: { _ in "This permanently deletes the thread and its agent history on your host. This cannot be undone." },
            rename: { task, title in client.send(.task(id: task.id, action: .rename(title: title))) },
            delete: { task in client.send(.task(id: task.id, action: .delete)) }
        )
    }
}

extension View {
    func taskConfirmations(rename: Binding<WireTask?>, delete: Binding<WireTask?>) -> some View {
        modifier(TaskConfirmations(taskToRename: rename, taskToDelete: delete))
    }
}
