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

    // The list and console split the height evenly. Not VSplitView: it hosts each pane
    // in its own AppKit view, which drops the tab picker's safe area, so the list ran under it.
    private var commands: some View {
        VStack(spacing: 0) {
            list
            Divider()
            console
        }
    }

    private var list: some View {
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
                // A plain row rather than a Section header: a section header sits 2pt
                // right of the "Commands" bar and draws a divider under itself. The
                // -2 lines its text up with "Commands".
                Text("Background")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, -2)
                    .padding(.top, project.commands.isEmpty ? 0 : 10)
                    .accessibilityAddTraits(.isHeader)
                    .listRowSeparator(.hidden)
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
            }
        }
        .scrollContentBackground(.hidden)
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

    private var console: some View {
        Group {
            if case .command(let id) = project.selectedCommand,
               let command = project.commands.first(where: { $0.id == id }) {
                CommandConsoleView(command: command, console: project.console(for: command), project: project)
                    .id(command.id)
            } else if case .background(let id) = project.selectedCommand,
                      let session = project.backgroundSessions.first(where: { $0.id == id }) {
                BackgroundSessionOutputView(session: session, project: project)
                    .id(session.id)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
