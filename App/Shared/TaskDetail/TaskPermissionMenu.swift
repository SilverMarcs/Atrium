import AtriumProtocol
import SwiftUI

/// The task's permission mode: a toolbar button showing the mode's symbol on
/// Mac, a row below the model menu on iPhone and iPad, and a new-chat row.
/// A mode the chat switches to only by restarting asks first, with an alert
/// its owner shows through `restartMode`, as a menu inside another menu can't.
struct TaskPermissionMenu: View {
    let selection: TaskPermissionSelection
    @Binding var restartMode: PermissionMode?
    let perform: (TaskAction) -> Void
    var showsToolbarLabel = false
    var isNewChatRow = false

    var body: some View {
        let title = selection.mode?.title ?? "Permissions"
        let symbol = selection.mode?.symbolName ?? "shield"

        Menu {
            Picker("Permissions", selection: Binding(get: { selection.mode }, set: { $0.map(choose) })) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbolName)
                        .tag(Optional(mode))
                        .disabled(!selection.available.contains(mode))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            if isNewChatRow {
                NewChatPickerLabel(title: title) {
                    Image(systemName: symbol)
                }
            } else if showsToolbarLabel {
                Label(title, systemImage: symbol)
                    .labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: symbol)
            }
        }
        .menuIndicator(showsToolbarLabel ? .hidden : .automatic)
        .disabled(!selection.canSelect)
        .help(title)
        .accessibilityLabel("Permissions")
        .accessibilityValue(title)
    }

    private func choose(_ mode: PermissionMode) {
        guard mode != selection.mode else { return }
        if selection.needingRestart.contains(mode) { restartMode = mode }
        else { perform(.setPermissionMode(mode)) }
    }
}

extension View {
    /// Asks whether to restart a chat for a mode it can't switch to otherwise.
    func permissionRestartAlert(_ mode: Binding<PermissionMode?>, provider: AgentProvider, perform: @escaping (TaskAction) -> Void) -> some View {
        alert(
            "Restart Chat?",
            isPresented: Binding(get: { mode.wrappedValue != nil }, set: { if !$0 { mode.wrappedValue = nil } }),
            presenting: mode.wrappedValue
        ) { mode in
            Button("Restart") { perform(.setPermissionMode(mode)) }
            Button("Cancel", role: .cancel) {}
        } message: { mode in
            Text("\(provider.name) started this chat without \(mode.title). It restarts to switch, once any running turn ends, and the conversation carries on.")
        }
    }
}
