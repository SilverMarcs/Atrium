import SwiftUI

/// The rename and delete prompts for a task, worded the same in both apps.
struct TaskConfirmationAlerts<Task: Equatable>: ViewModifier {
    @Binding var renaming: Task?
    @Binding var deleting: Task?
    let currentTitle: (Task) -> String
    let deletionMessage: (Task) -> String
    let rename: (Task, String) -> Void
    let delete: (Task) -> Void
    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Chat", isPresented: isPresenting($renaming), presenting: renaming) { task in
                TextField("Name", text: $title)
                Button("Rename") { rename(task, title) }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete Thread?", isPresented: isPresenting($deleting), presenting: deleting) { task in
                Button("Delete", role: .destructive) { delete(task) }
                Button("Cancel", role: .cancel) {}
            } message: { task in
                Text(deletionMessage(task))
            }
            .onChange(of: renaming) { _, task in
                title = task.map(currentTitle) ?? ""
            }
    }

    private func isPresenting(_ task: Binding<Task?>) -> Binding<Bool> {
        Binding(get: { task.wrappedValue != nil }, set: { if !$0 { task.wrappedValue = nil } })
    }
}

extension View {
    func taskConfirmationAlerts<Task: Equatable>(
        renaming: Binding<Task?>,
        deleting: Binding<Task?>,
        currentTitle: @escaping (Task) -> String,
        deletionMessage: @escaping (Task) -> String,
        rename: @escaping (Task, String) -> Void,
        delete: @escaping (Task) -> Void
    ) -> some View {
        modifier(TaskConfirmationAlerts(
            renaming: renaming, deleting: deleting, currentTitle: currentTitle,
            deletionMessage: deletionMessage, rename: rename, delete: delete
        ))
    }
}
