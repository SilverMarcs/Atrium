import AtriumClient
import AtriumProtocol
import SwiftUI

/// The column beside the chat: a page an agent showed, or the selected task's
/// project with its files, search, Git and commands, from whichever host it's on.
///
/// The page lives here rather than in a pane of its own because only real
/// split columns get their own section of the window's toolbar, which keeps
/// their buttons above them however the window is resized.
struct InspectorView: View {
    let item: HostTask?
    let project: Project?
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var page = InspectorPage()

    private var openPage: ChatPageBlock? { item.flatMap { app.inspectorPages.page(for: $0.id) } }
    private var frontPage: ChatPageBlock? { item.flatMap { app.inspectorPages.frontPage(for: $0.id) } }

    var body: some View {
        // Toolbar must hang off a stable container, not the tabContent switch:
        // attached to the conditional, its items are recreated (NSToolbar
        // remove+add, visible flicker) every time the selected tab branch changes.
        VStack(spacing: 0) { columnContent }
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
                    InspectorTabPicker(item: item, project: project)
                }
            }
            .task(id: PageLoad(task: item?.id, page: openPage)) {
                guard let item, let block = openPage else { return }
                await page.load(block.page, media: media(for: item), openURL: openURL)
            }
            // Pages are laid out for 320 points and up.
            .inspectorColumnWidth(min: frontPage != nil ? 320 : 240, ideal: frontPage != nil ? 480 : 240,
                                  max: frontPage != nil ? 1200 : 360)
    }

    @ViewBuilder
    private var columnContent: some View {
        if let item, let shown = frontPage {
            InspectorPageView(page: page, media: media(for: item))
                .safeAreaBar(edge: .bottom) { PageControls(item: item, page: page, shown: shown) }
        } else if let project {
            Group {
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
            // Every tab's foot switches branches, so what that asks to confirm
            // shows whichever tab is open.
            .sourceControlAlerts(project.git.model)
        } else {
            ContentUnavailableView("No Inspector", systemImage: "sidebar.right")
        }
    }

    private func media(for item: HostTask) -> ChatMedia {
        ChatMedia(host: item.host, taskID: item.task.id, directory: item.task.path)
    }
}

/// The inspector's tabs: the project's tools, then the chat's pages once it
/// has any, opening on the one last shown or else the newest. It reads the
/// chat for its pages, so only it follows the chat as replies arrive.
private struct InspectorTabPicker: View {
    let item: HostTask?
    let project: Project
    @Environment(AppModel.self) private var app

    var body: some View {
        let newestPage = item.flatMap { ConversationTurns.pageVersions(in: $0.host.conversations.displayMessages(for: $0.task.id)).first?.last }
        let showsPage = item.flatMap { app.inspectorPages.frontPage(for: $0.id) } != nil
        Picker("Inspector", selection: Binding {
            showsPage ? InspectorPane.page : .tab(project.selectedTab)
        } set: { pane in
            guard let item else { return }
            switch pane {
            case .page:
                if app.inspectorPages.page(for: item.id) == nil, let newestPage {
                    app.inspectorPages.show(newestPage, for: item.id)
                } else {
                    app.inspectorPages.bringToFront(for: item.id)
                }
            case .tab(let tab):
                app.showInspector(tab, in: project)
            }
        }) {
            ForEach(InspectorTab.allCases) { tab in
                Image(systemName: iconName(for: tab))
                    .help(tab.label)
                    .tag(InspectorPane.tab(tab))
            }
            if newestPage != nil || showsPage {
                Image(systemName: "doc.richtext")
                    .help("Pages")
                    .tag(InspectorPane.page)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .buttonSizing(.flexible)
        .labelsHidden()
        .padding(.horizontal, 10)
    }

    private func iconName(for tab: InspectorTab) -> String {
        if tab == .commands && project.commands.contains(where: { $0.isRunning }) {
            return "terminal.fill"
        }
        return tab.icon
    }
}

/// What the inspector's picker selects: the chat's page or one of the project's tools.
private enum InspectorPane: Hashable {
    case page
    case tab(InspectorTab)
}

/// What the inspector loads: the page it shows, in the chat it's beside.
private struct PageLoad: Equatable {
    let task: TaskRef?
    let page: ChatPageBlock?
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
