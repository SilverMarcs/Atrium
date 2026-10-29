import AtriumClient
import AtriumProtocol
import SwiftUI

/// The rename and delete prompts for a task, sending the result to its host.
struct TaskConfirmations: ViewModifier {
    @Binding var renaming: HostTask?
    @Binding var deleting: HostTask?
    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Chat", isPresented: isPresenting($renaming), presenting: renaming) { item in
                TextField("Name", text: $title)
                Button("Rename") { item.host.send(.task(id: item.task.id, action: .rename(title: title))) }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete Thread?", isPresented: isPresenting($deleting), presenting: deleting) { item in
                Button("Delete", role: .destructive) { item.host.send(.task(id: item.task.id, action: .delete)) }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text(item.host.deletionMessage(for: item.task))
            }
            .onChange(of: renaming?.id) {
                title = renaming?.task.title ?? ""
            }
    }

    private func isPresenting(_ item: Binding<HostTask?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

extension View {
    func taskConfirmations(rename: Binding<HostTask?>, delete: Binding<HostTask?>) -> some View {
        modifier(TaskConfirmations(renaming: rename, deleting: delete))
    }
}
