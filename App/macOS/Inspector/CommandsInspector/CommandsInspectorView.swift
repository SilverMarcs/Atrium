import SwiftUI

/// A project's saved commands, which run on its host, with the selected one's
/// output and input below the list.
struct CommandsInspectorView: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @State private var editing: CommandEditing?

    var body: some View {
        // Below the split, so the console sits above the footer rather than under it.
        VStack(spacing: 0) {
            commands
            InspectorScopeFooter(project: project)
        }
        .sheet(item: $editing) { editing in
            CommandEntrySheet(project: project, command: editing.command)
        }
    }

    private var commands: some View {
        VSplitView {
            List(selection: $project.selectedCommand) {
                ForEach(project.commands) { command in
                    CommandEntryRow(command: command, project: project) { editing = .edit(command) }
                        .tag(Project.CommandSelection.command(command.id))
                        .listRowSeparator(.hidden)
                }
                .onMove { source, destination in
                    guard let index = source.first else { return }
                    let command = project.commands[index]
                    project.send(.move(toIndex: destination > index ? destination - 1 : destination), to: command)
                }
                if !project.backgroundSessions.isEmpty {
                    Section {
                        ForEach(project.backgroundSessions) { session in
                            BackgroundSessionRow(session: session)
                                .tag(Project.CommandSelection.background(session.id))
                                .listRowSeparator(.hidden)
                                .contextMenu {
                                    Button("Open Chat", systemImage: "bubble.left") {
                                        app.selection = TaskRef(hostID: project.host.id, taskID: session.taskID)
                                    }
                                }
                        }
                    } header: {
                        Text("Background")
                            .font(.subheadline)
                            .fontWeight(.regular)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                Color.clear.frame(height: 50)
            }
            .scrollContentBackground(.hidden)
            .layoutPriority(1)

            // A selected background session shows nothing below.
            Group {
                if case .command(let id) = project.selectedCommand,
                   let command = project.commands.first(where: { $0.id == id }) {
                    CommandConsoleView(command: command, console: project.console(for: command), project: project)
                        .id(command.id)
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
                Button("New Command", systemImage: "plus") { editing = .new }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .padding(.top, 7)
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
