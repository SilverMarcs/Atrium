import SwiftUI

struct InspectorView: View {
    let workspace: Workspace
    @Environment(AppState.self) private var appState

    private var state: InspectorViewState { workspace.inspectorState }

    var body: some View {
        tabContent
            .toolbar {
                if let defaultCommand = workspace.defaultCommand {
                    ToolbarItem(placement: .primaryAction) {
                        runCommandControl(for: defaultCommand)
                    }
                }

                ToolbarSpacer(.flexible)
              
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appState.showingInspector.toggle()
                    } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                }
            }
            .safeAreaBar(edge: .top) {
                Picker("Inspector", selection: Bindable(state).selectedTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Image(systemName: iconName(for: tab))
                            .help(tab.label)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .buttonSizing(.flexible)
                .labelsHidden()
                .padding(.horizontal, 10)
            }
    }

    @ViewBuilder
    private func runCommandControl(for defaultCommand: Terminal) -> some View {
        let runnable = workspace.commands.filter { cmd in
            !(cmd.runScript?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }

        if runnable.count <= 1 {
            Button {
                trigger(defaultCommand)
            } label: {
                runIcon(for: defaultCommand)
            }
        } else {
            Menu {
                Picker("Default Command", selection: Binding(
                    get: { workspace.defaultCommand?.id ?? defaultCommand.id },
                    set: { newID in
                        if let cmd = workspace.commands.first(where: { $0.id == newID }) {
                            workspace.setDefaultCommand(cmd)
                        }
                    }
                )) {
                    ForEach(runnable) { cmd in
                        Label(cmd.title, systemImage: "play.fill").tag(cmd.id)
                            .labelStyle(.titleOnly)
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            } label: {
                runIcon(for: defaultCommand)
            } primaryAction: {
                trigger(defaultCommand)
            }
            .id(defaultCommand.id)
        }
    }

    private func trigger(_ cmd: Terminal) {
        if cmd.hasChildProcess {
            cmd.interrupt()
        } else {
            workspace.runCommand(cmd)
        }
    }

    private func runIcon(for cmd: Terminal) -> some View {
        Image(systemName: cmd.hasChildProcess ? "stop.fill" : "play.fill")
            .contentTransition(.symbolEffect(.replace))
    }

    private func iconName(for tab: InspectorTab) -> String {
        if tab == .commands && workspace.commands.contains(where: { $0.hasChildProcess }) {
            return "terminal.fill"
        }
        return tab.icon
    }

    @ViewBuilder
    private var tabContent: some View {
        switch state.selectedTab {
        case .files:
            FileTreeView(directoryURL: workspace.url, state: state.fileTree)
        case .search:
            SearchInspectorView(directoryURL: workspace.url, state: state.search)
        case .git:
            GitInspectorView(directoryURL: workspace.url, state: state.git) { url in
                state.revealInFileTree(url, relativeTo: workspace.url)
            }
        case .commands:
            CommandsInspectorView(workspace: workspace)
        }
    }

}
