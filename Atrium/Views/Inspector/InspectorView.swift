import SwiftUI

struct InspectorView: View {
    let workspace: Workspace
    @Environment(AppState.self) private var appState

    private var state: InspectorViewState { workspace.inspectorState }

    var body: some View {
        // Toolbar must hang off a stable container, not the tabContent switch:
        // attached to the conditional, its items are recreated (NSToolbar
        // remove+add, visible flicker) every time the selected tab branch changes.
        VStack(spacing: 0) { tabContent }
            .toolbar {
                // Always-present item: conditionally inserting/removing it (or
                // forcing recreation with .id) makes NSToolbar remove+add the
                // item on workspace switches, flashing the whole toolbar.
                ToolbarItem(placement: .primaryAction) {
                    runCommandControl
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

    // Structurally constant control (always a Menu): swapping the root view
    // type (Button <-> Menu) inside the ToolbarItem makes NSToolbar recreate
    // the item, flashing the whole toolbar on workspace switches.
    private var runCommandControl: some View {
        let runnable = workspace.commands.filter { cmd in
            !(cmd.runScript?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }
        let defaultCommand = workspace.defaultCommand

        return Menu {
            Picker("Default Command", selection: Binding(
                get: { defaultCommand?.id ?? runnable.first?.id },
                set: { newID in
                    if let cmd = workspace.commands.first(where: { $0.id == newID }) {
                        workspace.setDefaultCommand(cmd)
                    }
                }
            )) {
                ForEach(runnable) { cmd in
                    Label(cmd.title, systemImage: "play.fill").tag(Optional(cmd.id))
                        .labelStyle(.titleOnly)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            Image(systemName: (defaultCommand?.hasChildProcess ?? false) ? "stop.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
        } primaryAction: {
            if let defaultCommand {
                trigger(defaultCommand)
            }
        }
        .menuIndicator(runnable.count > 1 ? .visible : .hidden)
        .disabled(defaultCommand == nil)
    }

    private func trigger(_ cmd: Terminal) {
        if cmd.hasChildProcess {
            cmd.interrupt()
        } else {
            workspace.runCommand(cmd)
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
            FileTreeView(directoryURL: workspace.effectiveURL, state: state.fileTree)
        case .search:
            SearchInspectorView(directoryURL: workspace.effectiveURL, state: state.search)
        case .git:
            GitInspectorView(directoryURL: workspace.effectiveURL, state: state.git) { url in
                state.revealInFileTree(url, relativeTo: workspace.effectiveURL)
            }
        case .commands:
            CommandsInspectorView(workspace: workspace)
        }
    }

}
