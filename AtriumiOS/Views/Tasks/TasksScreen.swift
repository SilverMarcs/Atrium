import SwiftUI

/// The Mac sidebar on iPhone: active tasks, then collapsible Snoozed and
/// Settled sections. The filter shows a single section instead.
struct TasksScreen: View {
    @Environment(CompanionClient.self) private var client
    @Binding var selection: String?
    @State private var searchText = ""
    @State private var filter: TaskListFilter = .all
    @State private var isSnoozedExpanded = false
    @State private var isSettledExpanded = false
    @State private var showingNewTask = false
    @State private var taskToRename: WireTask?
    @State private var taskToDelete: WireTask?

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
        .contentMargins(.top, 10)
        .listStyle(.sidebar)
        .animation(.default, value: sections.ids)
        .animation(.default, value: filter)
        .refreshable { await client.perform(.refreshTasks) }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search tasks")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .navigationTitle(client.pairedHostName ?? "Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Unpair", systemImage: "power", role: .cancel, action: client.unpair)
            }
            ToolbarItem(placement: .topBarTrailing) {
                TaskFilterMenu(filter: $filter)
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("New Task", systemImage: "square.and.pencil") { showingNewTask = true }
                    .disabled(!client.isConnected)
            }
        }
        .overlay {
            TasksPlaceholder(isLoaded: client.tasks != nil, isSearching: isSearching, isEmpty: visibleTasksAreEmpty(sections))
        }
        .sheet(isPresented: $showingNewTask) {
            NewTaskSheet()
        }
        .taskConfirmations(rename: $taskToRename, delete: $taskToDelete)
    }

    /// Searching, or filtering to this section alone, keeps it expanded, as the
    /// Mac sidebar does while searching.
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
