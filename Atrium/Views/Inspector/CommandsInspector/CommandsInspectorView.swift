import SwiftUI

struct CommandsInspectorView: View {
    let workspace: Workspace
    @Environment(AppState.self) private var appState
    // @State private var showKillAllAlert = false

    var body: some View {
        @Bindable var state = workspace.inspectorState
        VSplitView {
            List(workspace.commands, selection: $state.selectedCommand) { terminal in
                CommandEntryRow(terminal: terminal)
                    .tag(terminal)
                    .listRowSeparator(.hidden)
            }
            .safeAreaInset(edge: .top) {
                Color.clear.frame(height: 50)
            }
            .scrollContentBackground(.hidden)
            .layoutPriority(1)

            Group {
                if let terminal = state.selectedCommand {
                    CommandTerminalOutputView(terminal: terminal)
                        // .id(terminal.id)
                } else {
                    Color.clear
                }
            }
            .frame(minHeight: 390, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
        }
        .safeAreaBar(edge: .top) {
            HStack {
                Text("Commands")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                // Button {
                //     showKillAllAlert = true
                // } label: {
                //     Image(systemName: "xmark")
                // }
                // .buttonStyle(.borderless)
                // .disabled(workspace.commands.isEmpty)

                Button {
                    let terminal = workspace.addCommand()
                    state.selectedCommand = terminal
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .padding(.top, 7)
        }
        // .alert("Kill all terminals?", isPresented: $showKillAllAlert) {
        //     Button("Kill All", role: .destructive) {
        //         workspace.removeAllCommands()
        //     }
        //     Button("Cancel", role: .cancel) {}
        // } message: {
        //     Text("This will terminate every running shell and remove all entries from the list.")
        // }
    }
}