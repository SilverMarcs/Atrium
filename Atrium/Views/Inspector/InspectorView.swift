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
                        Button {
                            if defaultCommand.hasChildProcess {
                                defaultCommand.interrupt()
                            } else {
                                workspace.runCommand(defaultCommand)
                            }
                        } label: {
                            Image(systemName: defaultCommand.hasChildProcess ? "stop.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
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
