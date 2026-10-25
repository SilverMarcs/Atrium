import SwiftUI

struct ThreadListView: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    @Environment(TaskSessionController.self) private var sessions
    @Environment(AppState.self) private var appState
    let searchText: String
    @State private var threadToDelete: AgentThread?
    @State private var isSettledExpanded = false
    @State private var isSnoozedExpanded = false
    @State private var threadToRename: AgentThread?

    private var threads: [AgentThread] {
        integrations.visibleThreads(matching: searchText)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var unavailableProviderNames: String {
        integrations.enabledProviders
            .filter { integrations.errors[$0] != nil }
            .map(\.name)
            .formatted(.list(type: .and))
    }

    var body: some View {
        let sections = TaskSections(
            threads,
            isSettled: { integrations.settledThreadIDs.contains($0.id) },
            isSnoozed: { integrations.snoozedUntil[$0.id] != nil }
        )
        let settledThreads = sections.settled
        let snoozedThreads = sections.snoozed
        let regularThreads = sections.active

        List(selection: Binding<String?>(get: { appState.selectedThreadID }, set: { id in
            guard let thread = threads.first(where: { $0.id == id }) else { return }
            sessions.open(thread)
        })) {
            ThreadListRows(threads: regularThreads, requestDeletion: requestDeletion, requestRename: requestRename)

            if !snoozedThreads.isEmpty {
                if isSearching {
                    Section("Snoozed") {
                        ThreadListRows(threads: snoozedThreads, requestDeletion: requestDeletion, requestRename: requestRename)
                    }
                } else {
                    Section("Snoozed", isExpanded: $isSnoozedExpanded.animation()) {
                        ThreadListRows(threads: snoozedThreads, requestDeletion: requestDeletion, requestRename: requestRename)
                    }
                }
            }

            if !settledThreads.isEmpty {
                if isSearching {
                    Section("Settled") {
                        ThreadListRows(threads: settledThreads, requestDeletion: requestDeletion, requestRename: requestRename)
                    }
                } else {
                    Section("Settled", isExpanded: $isSettledExpanded.animation()) {
                        ThreadListRows(threads: settledThreads, requestDeletion: requestDeletion, requestRename: requestRename)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .animation(.default, value: sections.ids)
        .environment(\.sidebarRowSize, .medium) //
        .overlay {
            if !unavailableProviderNames.isEmpty {
                ContentUnavailableView {
                    Label("\(unavailableProviderNames) unavailable", systemImage: "exclamationmark.circle")
                } description: {
                    Text("Try again to load tasks.")
                } actions: {
                    Button("Retry") { Task { await integrations.refresh() } }
                        .disabled(integrations.isRefreshing)
                }
            } else if threads.isEmpty {
                if !integrations.isEnabled {
                    ContentUnavailableView {
                        Label("Enable an Integration", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("Enable Codex or Claude in Settings to open tasks.")
                    } actions: {
                        SettingsLink { Text("Open Settings") }
                    }
                } else if integrations.isRefreshing {
                    ProgressView("Loading threads…")
                } else {
                    ContentUnavailableView(isSearching ? "No Results" : "No Tasks", systemImage: "bubble.left.and.bubble.right", description: Text("Use Compose to start a task."))
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            HStack {
                Button("New Chat", systemImage: "square.and.pencil") { appState.showingCompose = true }
                    .disabled(sessions.isOpening || !integrations.isEnabled)
                Spacer()
            }
            .buttonStyle(.plain)
            .padding(13)
        }
        .sheet(isPresented: Bindable(appState).showingCompose) { ComposeThreadView() }
        .taskConfirmationAlerts(
            renaming: $threadToRename,
            deleting: $threadToDelete,
            currentTitle: \.title,
            deletionMessage: integrations.deletionMessage,
            rename: { thread, title in Task { await integrations.renameThread(thread, to: title) } },
            delete: { thread in Task { await sessions.delete(thread) } }
        )
        .alert("Couldn’t Update Thread", isPresented: Binding(
            get: { integrations.actionError != nil && !appState.showingCompose && threadToRename == nil },
            set: { if !$0 { integrations.actionError = nil } }
        )) {
            Button("OK") { integrations.actionError = nil }
        } message: {
            Text(integrations.actionError ?? "")
        }
    }

    private func requestDeletion(_ thread: AgentThread) {
        guard !sessions.isOpening, integrations.canDelete(thread) else { return }
        threadToDelete = thread
    }

    private func requestRename(_ thread: AgentThread) {
        guard !sessions.isOpening, integrations.canRename(thread) else { return }
        integrations.actionError = nil
        threadToRename = thread
    }
}
