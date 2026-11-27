import SwiftUI

/// The column beside the chat: the selected task's project with its files,
/// Git and commands, from whichever host it's on, and the chat's browser.
struct InspectorView: View {
    let item: HostTask?
    let project: Project?
    @Environment(AppModel.self) private var app

    var body: some View {
        // Toolbar must hang off a stable container, not the tabContent switch:
        // attached to the conditional, its items are recreated (NSToolbar
        // remove+add, visible flicker) every time the selected tab branch changes.
        VStack(spacing: 0) { columnContent }
            // Full height whatever the tab shows, so the tab picker stays on top.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                if let project {
                    // Present for every project: conditionally inserting/removing
                    // it (or forcing recreation with .id) makes NSToolbar remove+add
                    // the item on workspace switches, flashing the whole toolbar.
                    ToolbarItem(placement: .primaryAction) {
                        RunCommandMenu(project: project)
                    }
                }

                ToolbarSpacer(.flexible)

                ToolbarItem(placement: .primaryAction) {
                    Button("Inspector", systemImage: "sidebar.trailing") {
                        app.showingInspector.toggle()
                    }
                }
            }
            .safeAreaBar(edge: .top) {
                if let project {
                    InspectorTabPicker(project: project)
                }
            }
            // One width for every tab, which can be dragged wide for the browser.
            .inspectorColumnWidth(min: 240, ideal: 280, max: 900)
            .remembersInspectorWidth(for: item?.id)
    }

    @ViewBuilder
    private var columnContent: some View {
        if let project {
            Group {
                switch app.inspectorState.tab {
                case .files:
                    FileTreeView(project: project)
                case .search:
                    SearchInspectorView(project: project)
                case .git:
                    GitInspectorView(state: project.git)
                case .commands:
                    CommandsInspectorView(project: project)
                case .browser:
                    BrowserInspectorView(item: item)
                case .simulator:
                    SimulatorInspectorView(item: item)
                }
            }
            // The project tabs' feet switch branches, so what that asks to
            // confirm shows whichever tab is open.
            .sourceControlAlerts(project.git.model)
        } else {
            ContentUnavailableView("No Inspector", systemImage: "sidebar.right")
        }
    }
}

/// The inspector's tabs: the project's tools and the chat's browser.
private struct InspectorTabPicker: View {
    let project: Project
    @Environment(AppModel.self) private var app

    var body: some View {
        let runningCount = project.runningCount
        Picker("Inspector", selection: Binding {
            app.inspectorState.tab
        } set: { tab in
            app.showInspector(tab, in: project)
        }) {
            ForEach(InspectorTab.shown) { tab in
                Image(systemName: iconName(for: tab, runningCount: runningCount))
                    .help(helpText(for: tab, runningCount: runningCount))
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .buttonSizing(.flexible)
        .labelsHidden()
        .padding(.horizontal, 10)
    }

    private func iconName(for tab: InspectorTab, runningCount: Int) -> String {
        if tab == .commands && runningCount > 0 {
            return "terminal.fill"
        }
        return tab.icon
    }

    private func helpText(for tab: InspectorTab, runningCount: Int) -> String {
        if tab == .commands && runningCount > 0 {
            return "\(tab.label) (\(runningCount) running)"
        }
        return tab.label
    }
}

/// Runs the project's default command, or picks another from its menu.
// Structurally constant control (always a Menu): swapping the root view
// type (Button <-> Menu) inside the ToolbarItem makes NSToolbar recreate
// the item, flashing the whole toolbar on workspace switches.
private struct RunCommandMenu: View {
    let project: Project

    var body: some View {
        let runnable = project.commands.filter(\.canRun)
        let defaultCommand = project.defaultCommand

        Menu {
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
                project.toggle(defaultCommand)
            }
        }
        .menuIndicator(runnable.count > 1 ? .visible : .hidden)
        .disabled(defaultCommand == nil)
    }
}
