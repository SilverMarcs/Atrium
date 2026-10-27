import SwiftUI

/// The host sidebar on iPhone: active tasks, then collapsible Snoozed and
/// Settled sections. The filter shows a single section instead.
struct TasksScreen: View {
    @Environment(CompanionClient.self) private var client
    @Binding var selection: String?
    let onEditHosts: () -> Void
    @State private var searchText = ""
    @State private var filter: TaskListFilter = .all
    @State private var isSnoozedExpanded = false
    @State private var isSettledExpanded = false
    @State private var showingNewTask = false
    @State private var taskToRename: WireTask?
    @State private var taskToDelete: WireTask?

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        let sections = TaskSections(
            tasks: client.tasks?.tasks ?? [],
            workspaces: client.tasks?.workspaces ?? [],
            query: searchText
        )
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
            if client.isConnected { await client.perform(.refreshTasks) } else { client.retryNow() }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search tasks")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .navigationTitle(client.pairedHostName ?? "Tasks")
        .modifier(ConnectionStatusSubtitle())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            HostSwitcherMenuItems(onEdit: onEditHosts)
        }
        .toolbar {
            // iPad leaves out the filter and starts tasks from the top bar.
            if isPhone {
                ToolbarItem(placement: .topBarTrailing) {
                    TaskFilterMenu(filter: $filter)
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    NewTaskButton(action: { showingNewTask = true }, openProject: { openDraft(in: $0) })
                }
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            if isPhone {
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    NewTaskButton(action: { showingNewTask = true }, openProject: { openDraft(in: $0) })
                }
            }
        }
        .overlay {
            TasksPlaceholder(isLoaded: client.tasks != nil, isSearching: isSearching, isEmpty: visibleTasksAreEmpty(sections))
        }
        .sheet(isPresented: $showingNewTask) {
            NewTaskSheet { openDraft(in: $0, provider: $1) }
        }
        .taskConfirmations(rename: $taskToRename, delete: $taskToDelete)
    }

    /// Searching, or filtering to this section alone, keeps it expanded, as the
    /// host sidebar does while searching.
    @ViewBuilder
    private func collapsibleSection(_ title: String, tasks: [WireTask], isExpanded: Binding<Bool>, isSearching: Bool) -> some View {
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

    private func rows(_ tasks: [WireTask]) -> some View {
        ForEach(tasks) { task in
            TaskRow(task: task)
                .tag(task.id)
            .contextMenu {
                TaskContextMenu(state: task.menuState) { perform($0, on: task) }
            }
            .taskSwipeActions(task.menuState) { perform($0, on: task) }
        }
    }

    /// Opens a new task as a draft, which the host creates once its first
    /// prompt is sent.
    private func openDraft(in workspaceID: UUID, provider: AgentProvider? = nil) {
        guard let id = client.openDraft(in: workspaceID, provider: provider) else { return }
        selection = id
    }

    private func perform(_ action: TaskMenuAction, on task: WireTask) {
        switch action {
        case .rename: taskToRename = task
        case .delete: taskToDelete = task
        default: client.perform(action, on: task)
        }
    }

    private func visibleTasksAreEmpty(_ sections: TaskSections<WireTask>) -> Bool {
        switch filter {
        case .all: sections.isEmpty
        case .active: sections.active.isEmpty
        case .snoozed: sections.snoozed.isEmpty
        case .settled: sections.settled.isEmpty
        }
    }
}
