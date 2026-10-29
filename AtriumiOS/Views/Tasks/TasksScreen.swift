import AtriumClient
import AtriumProtocol
import SwiftUI

/// Every connected host's tasks in one list: active tasks, then collapsible
/// Snoozed and Settled sections. The filter shows a single section instead,
/// and the title menu narrows the list to one host.
struct TasksScreen: View {
    @Environment(HostDirectory.self) private var hosts
    @Binding var selection: TaskRef?
    let onEditHosts: () -> Void
    @State private var searchText = ""
    @State private var filter: TaskListFilter = .all
    @State private var isSnoozedExpanded = false
    @State private var isSettledExpanded = false
    @State private var showingProjects = false
    @State private var taskToRename: HostTask?
    @State private var taskToDelete: HostTask?

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        let tasks = hosts.tasks.filter { item in
            TaskSearch.matches(searchText, in: item.task.title, item.task.projectName, item.task.directory, item.workspace?.name, item.host.name)
        }
        let sections = TaskSections(tasks, isSettled: \.task.isSettled, isSnoozed: { $0.task.snoozedUntil != nil })
        let isSearching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty

        // The same sections are always declared and only shown or hidden, so
        // changing the filter animates rows instead of rebuilding the list.
        List(selection: $selection) {
            if filter == .all || filter == .active {
                Section {
                    rows(sections.active)
                }
            }
            if filter == .all || filter == .snoozed {
                collapsibleSection("Snoozed", tasks: sections.snoozed, isExpanded: $isSnoozedExpanded, isSearching: isSearching)
            }
            if filter == .all || filter == .settled {
                collapsibleSection("Settled", tasks: sections.settled, isExpanded: $isSettledExpanded, isSearching: isSearching)
            }
        }
        .contentMargins(.top, isPhone ? 10 : 0)
        .listStyle(.sidebar)
        .animation(.default, value: [sections.active.map(\.id), sections.snoozed.map(\.id), sections.settled.map(\.id)])
        .animation(.default, value: filter)
        .refreshable {
            await withDiscardingTaskGroup { group in
                for host in hosts.visibleHosts {
                    if host.isConnected {
                        group.addTask { await host.perform(.refreshTasks) }
                    } else {
                        host.retryNow()
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search tasks")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .navigationTitle(hosts.filterTitle)
        .modifier(ConnectionStatusSubtitle(hosts: hosts.visibleHosts))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            HostFilterPicker(hosts: hosts)
            Divider()
            Button("Edit Hosts…", systemImage: "pencil", action: onEditHosts)
        }
        .toolbar {
            // iPad leaves out the filter and projects, and starts chats from the top bar.
            if isPhone {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Projects", systemImage: "folder") { showingProjects = true }
                        .disabled(!hosts.hosts.contains(where: \.isConnected))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    TaskFilterMenu(filter: $filter)
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New Chat", systemImage: "square.and.pencil") { hosts.openNewChat() }
                        .disabled(!hosts.canStartNewChat)
                }
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            if isPhone {
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("New Chat", systemImage: "square.and.pencil") { hosts.openNewChat() }
                        .disabled(!hosts.canStartNewChat)
                }
            }
        }
        .overlay {
            TasksPlaceholder(isLoaded: hosts.hasLoadedTasks, isSearching: isSearching, isEmpty: visibleTasksAreEmpty(sections))
        }
        .sheet(isPresented: $showingProjects) {
            ProjectsSheet(hosts: hosts)
        }
        .taskConfirmations(rename: $taskToRename, delete: $taskToDelete)
    }

    /// Searching, or filtering to this section alone, keeps it expanded, as the
    /// Mac's sidebar does while searching.
    @ViewBuilder
    private func collapsibleSection(_ title: String, tasks: [HostTask], isExpanded: Binding<Bool>, isSearching: Bool) -> some View {
        if !tasks.isEmpty {
            let isForcedOpen = isSearching || filter != .all
            Section(title, isExpanded: Binding(
                get: { isForcedOpen || isExpanded.wrappedValue },
                set: { isExpanded.wrappedValue = $0 }
            ).animation()) {
                rows(tasks)
            }
        }
    }

    private func rows(_ tasks: [HostTask]) -> some View {
        ForEach(tasks) { item in
            TaskRow(item: item, showsHost: hosts.showsHostNames)
                .tag(item.id)
                .contextMenu {
                    TaskContextMenu(state: item.task.menuState) { perform($0, on: item) }
                }
                .taskSwipeActions(item.task.menuState) { perform($0, on: item) }
        }
    }

    private func perform(_ action: TaskMenuAction, on item: HostTask) {
        switch action {
        case .rename: taskToRename = item
        case .delete: taskToDelete = item
        default: hosts.perform(action, on: item)
        }
    }

    private func visibleTasksAreEmpty(_ sections: TaskSections<HostTask>) -> Bool {
        switch filter {
        case .all: sections.isEmpty
        case .active: sections.active.isEmpty
        case .snoozed: sections.snoozed.isEmpty
        case .settled: sections.settled.isEmpty
        }
    }
}
