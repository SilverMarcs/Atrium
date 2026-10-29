import AtriumProtocol
import SwiftUI

/// The selected task's project: its files, search, Git and commands, from
/// whichever host it's on.
struct InspectorView: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app

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
                    Button("Inspector", systemImage: "sidebar.trailing") {
                        app.showingInspector.toggle()
                    }
                }
            }
            .safeAreaBar(edge: .top) {
                Picker("Inspector", selection: $project.selectedTab) {
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
        let runnable = project.commands.filter(\.canRun)
        let defaultCommand = project.defaultCommand

        return Menu {
            Picker("Default Command", selection: Binding(
                get: { defaultCommand?.id ?? runnable.first?.id },
                set: { newID in
                    if let command = project.commands.first(where: { $0.id == newID }) {
                        project.send(.setDefault, to: command)
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
            Image(systemName: (defaultCommand?.isRunning ?? false) ? "stop.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
        } primaryAction: {
            if let defaultCommand {
                trigger(defaultCommand)
            }
        }
        .menuIndicator(runnable.count > 1 ? .visible : .hidden)
        .disabled(defaultCommand == nil)
    }

    private func trigger(_ command: WireCommand) {
        project.send(command.isRunning ? .stop : .run, to: command)
    }

    private func iconName(for tab: InspectorTab) -> String {
        if tab == .commands && project.commands.contains(where: { $0.isRunning }) {
            return "terminal.fill"
        }
        return tab.icon
    }

    @ViewBuilder
    private var tabContent: some View {
        switch project.selectedTab {
        case .files:
            FileTreeView(project: project)
        case .search:
            SearchInspectorView(project: project)
        case .git:
            GitInspectorView(state: project.git)
        case .commands:
            CommandsInspectorView(project: project)
        }
    }

}
