import SwiftUI

/// A project's saved commands. On this Mac's own host each runs in a terminal
/// shown below the list; on another host they run there, with their state here.
struct CommandsInspectorView: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @State private var editing: CommandEditing?

    var body: some View {
        VSplitView {
            List(selection: $project.selectedCommandID) {
                ForEach(project.commands) { command in
                    CommandEntryRow(command: command, project: project) { editing = .edit(command) }
                        .tag(command.id)
                        .listRowSeparator(.hidden)
                }
                .onMove { source, destination in
                    guard let index = source.first else { return }
                    let command = project.commands[index]
                    project.send(.move(toIndex: destination > index ? destination - 1 : destination), to: command)
                }
            }
            .safeAreaInset(edge: .top) {
                Color.clear.frame(height: 50)
            }
            .scrollContentBackground(.hidden)
            .layoutPriority(1)

            if project.isLocal {
                Group {
                    if let id = project.selectedCommandID,
                       let command = project.commands.first(where: { $0.id == id }),
                       let terminal = app.terminals.command(id, in: project.workspaceID) {
                        CommandTerminalOutputView(command: command, terminal: terminal, project: project)
                    } else {
                        Color.clear
                    }
                }
                .frame(minHeight: 390, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaBar(edge: .top) {
            HStack {
                Text("Commands")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("New Command", systemImage: "plus") { editing = .new }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .padding(.top, 7)
        }
        .sheet(item: $editing) { editing in
            CommandEntrySheet(project: project, command: editing.command)
        }
    }
}

/// The command sheet being shown: a new command, or one being edited.
enum CommandEditing: Identifiable {
    case new
    case edit(WireCommand)

    var id: UUID? { command?.id }

    var command: WireCommand? {
        if case .edit(let command) = self { command } else { nil }
    }
}
