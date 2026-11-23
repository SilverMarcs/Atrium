import SwiftUI

/// The rename and delete prompts for tasks, sending the result to their hosts.
struct TaskConfirmations: ViewModifier {
    @Binding var renaming: HostTask?
    @Binding var deleting: [HostTask]
    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Chat", isPresented: isPresenting($renaming), presenting: renaming) { item in
                TextField("Name", text: $title)
                Button("Rename") { item.host.send(.task(id: item.task.id, action: .rename(title: title))) }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert(deletionTitle, isPresented: isDeleting, presenting: deleting) { items in
                Button("Delete", role: .destructive) {
                    for item in items { item.host.send(.task(id: item.task.id, action: .delete)) }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: { items in
                if items.count == 1, let item = items.first {
                    Text(item.host.deletionMessage(for: item.task))
                } else {
                    Text("This permanently deletes these \(items.count) threads and their agent history. Some agents also delete the child threads they created. Open tasks for them will be stopped. This cannot be undone.")
                }
            }
            .onChange(of: renaming?.id) {
                title = renaming?.task.title ?? ""
            }
    }

    private var deletionTitle: String {
        deleting.count > 1 ? "Delete \(deleting.count) Threads?" : "Delete Thread?"
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })
    }

    private func isPresenting(_ item: Binding<HostTask?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

extension View {
    func taskConfirmations(rename: Binding<HostTask?>, delete: Binding<[HostTask]>) -> some View {
        modifier(TaskConfirmations(renaming: rename, deleting: delete))
    }
}
