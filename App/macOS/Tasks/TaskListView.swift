import AtriumClient
import AtriumProtocol
import SwiftUI

/// Every connected host's tasks in one list, narrowed by the host filter.
struct TaskListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let searchText: String
    @State private var taskToDelete: HostTask?
    @State private var taskToRename: HostTask?
    @State private var isSettledExpanded = false
    @State private var isSnoozedExpanded = false
    /// The command-line clients whose sessions are shown, by name.
    @State private var expandedDevices: Set<String> = []

    private var hosts: HostDirectory { app.hosts }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tasks: [HostTask] {
        hosts.listedTasks.filter(matchesSearch)
    }

    private func matchesSearch(_ item: HostTask) -> Bool {
        TaskSearch.matches(searchText, in: item.task.title, item.task.projectName, item.task.directory, item.host.name)
    }

    /// Hosts listed whose agents couldn't load their tasks.
    private var unavailable: [String] {
        hosts.visibleHosts.flatMap { host in
            (host.tasks?.providers ?? []).filter { $0.isAvailable && $0.error != nil }.map { provider in
                hosts.showsHostNames ? "\(provider.provider.name) on \(host.name)" : provider.provider.name
            }
        }
    }

    var body: some View {
        let sections = TaskSections(tasks, isSettled: \.task.isSettled, isSnoozed: { $0.task.isSnoozed })

        let deviceTasks = hosts.deviceTasks.map { ($0.device, $0.tasks.filter(matchesSearch)) }.filter { !$0.1.isEmpty }

        // A subagent on screen isn't listed, so no row is selected and choosing its session's row goes back.
        List(selection: Bindable(app).selection) {
            rows(sections.active)
            if !sections.snoozed.isEmpty {
                Section("Snoozed", isExpanded: Binding(get: { isSearching || isSnoozedExpanded }, set: { isSnoozedExpanded = $0 }).animation()) {
                    rows(sections.snoozed)
                }
            }
            if !sections.settled.isEmpty {
                Section("Settled", isExpanded: Binding(get: { isSearching || isSettledExpanded }, set: { isSettledExpanded = $0 }).animation()) {
                    rows(sections.settled)
                }
            }
            ForEach(deviceTasks, id: \.0) { device, tasks in
                Section(device, isExpanded: Binding(
                    get: { isSearching || expandedDevices.contains(device) },
                    set: { if $0 { expandedDevices.insert(device) } else { expandedDevices.remove(device) } }
                ).animation()) {
                    rows(tasks)
                }
            }
        }
        .listStyle(.sidebar)
        .animation(.default, value: sections.ids + deviceTasks.flatMap(\.1).map(\.id))
        .environment(\.sidebarRowSize, .medium)
        .overlay { placeholder(isEmpty: tasks.isEmpty && deviceTasks.isEmpty) }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem {
                SidebarMenu()
            }
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") { hosts.openNewChat() }
                    .help("New Chat")
                    .disabled(!hosts.canStartNewChat)
            }
        }
        .taskConfirmations(rename: $taskToRename, delete: $taskToDelete)
        .alert("Couldn’t Update Thread", isPresented: Binding(
            get: { hosts.actionError != nil && !app.showingProjects && taskToRename == nil },
            set: { if !$0 { hosts.actionError = nil } }
        )) {
            Button("OK") { hosts.actionError = nil }
        } message: {
            Text(hosts.actionError ?? "")
        }
    }

    private func rows(_ items: [HostTask]) -> some View {
        ForEach(items) { item in
            TaskRow(item: item, showsHost: hosts.showsHostNames)
                .tag(item.id)
                .contextMenu {
                    TaskContextMenu(state: item.menuState) { perform($0, on: item) }
                }
                .taskSwipeActions(item.task.menuState) { perform($0, on: item) }
        }
    }

    @ViewBuilder
    private func placeholder(isEmpty: Bool) -> some View {
        if !unavailable.isEmpty {
            ContentUnavailableView {
                Label("\(unavailable.formatted(.list(type: .and))) unavailable", systemImage: "exclamationmark.circle")
            } description: {
                Text("Try again to load tasks.")
            } actions: {
                Button("Retry") {
                    for host in hosts.visibleHosts { host.send(.refreshTasks) }
                }
                .disabled(hosts.visibleHosts.contains { $0.tasks?.isRefreshing == true })
            }
        } else if isEmpty {
            if !hosts.hasLoadedTasks || hosts.visibleHosts.contains(where: { $0.tasks?.isRefreshing == true }) {
                ProgressView()
            } else if !hosts.visibleHosts.contains(where: { $0.tasks?.providers.contains(where: \.isAvailable) == true }) {
                ContentUnavailableView {
                    Label("No Agents Found", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Install Claude Code or Codex. Atrium finds them on its own.")
                } actions: {
                    Button("Check Again") {
                        for host in hosts.visibleHosts { host.send(.refreshTasks) }
                    }
                }
            } else if isSearching {
                ContentUnavailableView.search(text: searchText)
            } else if hosts.visibleHosts.allSatisfy({ $0.tasks?.workspaces.isEmpty != false }) {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder")
                } description: {
                    Text("Add a project folder to start chats in it.")
                } actions: {
                    Button("Add Project…") { app.showingProjects = true }
                        .disabled(!hosts.hosts.contains(where: \.isConnected))
                }
            } else {
                ContentUnavailableView("No Tasks", systemImage: "bubble.left.and.bubble.right", description: Text("Use New Chat to start a task."))
            }
        }
    }

    /// Menu actions, undoable where the sidebar always allowed it.
    private func perform(_ action: TaskMenuAction, on item: HostTask) {
        switch action {
        case .rename:
            taskToRename = item
        case .delete:
            taskToDelete = item
        default:
            hosts.perform(action, on: item)
            registerUndo(of: action, on: item)
        }
    }

    private func registerUndo(of action: TaskMenuAction, on item: HostTask) {
        let reverse: TaskAction
        switch action {
        case .settle: reverse = .restore
        case .restore: reverse = .settle
        case .snooze: reverse = .unsnooze
        case .unsnooze:
            guard let date = item.task.snoozedUntil else { return }
            reverse = .snooze(until: date)
        default: return
        }
        let host = item.host
        let id = item.task.id
        undoManager?.registerUndo(withTarget: host) { host in
            host.send(.task(id: id, action: reverse))
        }
        undoManager?.setActionName(action.title)
    }
}
