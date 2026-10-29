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

    private var hosts: HostDirectory { app.hosts }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tasks: [HostTask] {
        hosts.tasks.filter { item in
            TaskSearch.matches(searchText, in: item.task.title, item.task.projectName, item.task.directory, item.host.name)
        }
    }

    /// Hosts listed whose agents couldn't load their tasks.
    private var unavailable: [String] {
        hosts.visibleHosts.flatMap { host in
            (host.tasks?.providers ?? []).filter { $0.isEnabled && $0.error != nil }.map { provider in
                hosts.showsHostNames ? "\(provider.provider.name) on \(host.name)" : provider.provider.name
            }
        }
    }

    var body: some View {
        let sections = TaskSections(tasks, isSettled: \.task.isSettled, isSnoozed: { $0.task.isSnoozed })

        @Bindable var app = app
        List(selection: $app.selection) {
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
        }
        .listStyle(.sidebar)
        .animation(.default, value: sections.ids)
        .environment(\.sidebarRowSize, .medium)
        .overlay { placeholder(isEmpty: tasks.isEmpty) }
        .toolbar {
            if hosts.hosts.count > 1 {
                ToolbarItem {
                    Menu("Hosts", systemImage: hosts.filter == nil ? "square.stack.3d.up" : "macbook") {
                        HostFilterPicker(hosts: hosts)
                            .pickerStyle(.inline)
                            .labelsHidden()
                    }
                    .help("Show tasks from one host or all of them")
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            HStack {
                Button("New Chat", systemImage: "square.and.pencil") { hosts.openNewChat() }
                    .disabled(!hosts.canStartNewChat)
                Button("Projects", systemImage: "folder") { app.showingProjects = true }
                    .labelStyle(.iconOnly)
                    .help("Manage projects")
                    .disabled(!hosts.hosts.contains(where: \.isConnected))
                Spacer()
            }
            .buttonStyle(.plain)
            .padding(13)
        }
        .sheet(isPresented: Bindable(app).showingProjects) { ProjectsSheet(hosts: hosts) }
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
                    TaskContextMenu(state: item.task.menuState) { perform($0, on: item) }
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
            if !hosts.visibleHosts.contains(where: { $0.tasks?.providers.contains(where: \.isEnabled) == true }) {
                if hosts.hasLoadedTasks {
                    ContentUnavailableView {
                        Label("Enable an Integration", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("Enable Codex or Claude in Settings to open tasks.")
                    } actions: {
                        SettingsLink { Text("Open Settings") }
                    }
                } else {
                    ProgressView()
                }
            } else if hosts.visibleHosts.contains(where: { $0.tasks?.isRefreshing == true }) {
                ProgressView("Loading threads…")
            } else {
                ContentUnavailableView(isSearching ? "No Results" : "No Tasks", systemImage: "bubble.left.and.bubble.right", description: Text("Use New Chat to start a task."))
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
