import SwiftUI

struct ThreadListView: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    @Environment(TaskSessionController.self) private var sessions
    @Environment(AppState.self) private var appState
    let searchText: String
    @State private var threadToDelete: AgentThread?
    @State private var showingDeleteConfirmation = false
    @State private var isSettledExpanded = false
    @State private var isSnoozedExpanded = false
    @State private var threadToRename: AgentThread?
    @State private var showingRename = false
    @State private var renamedTitle = ""

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
        let settledThreads = threads.filter { integrations.settledThreadIDs.contains($0.id) }
        let snoozedThreads = threads.filter { integrations.snoozedUntil[$0.id] != nil && !integrations.settledThreadIDs.contains($0.id) }
        let regularThreads = threads.filter { integrations.snoozedUntil[$0.id] == nil && !integrations.settledThreadIDs.contains($0.id) }

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
        .animation(.default, value: [regularThreads.map(\.id), snoozedThreads.map(\.id), settledThreads.map(\.id)])
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
        .alert("Rename Chat", isPresented: $showingRename, presenting: threadToRename) { thread in
            TextField("Name", text: $renamedTitle)
            Button("Rename") {
                let name = renamedTitle
                Task { await integrations.renameThread(thread, to: name) }
                threadToRename = nil
            }
            .disabled(renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !integrations.canRename(thread))
            Button("Cancel", role: .cancel) { threadToRename = nil }
        }
        .alert("Delete Thread?", isPresented: $showingDeleteConfirmation, presenting: threadToDelete) { thread in
            Button("Delete", role: .destructive) {
                Task { await sessions.delete(thread) }
                threadToDelete = nil
            }
            Button("Cancel", role: .cancel) { threadToDelete = nil }
        }
        .alert("Couldn’t Update Thread", isPresented: Binding(
            get: { integrations.actionError != nil && !appState.showingCompose && !showingRename },
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
        showingDeleteConfirmation = true
    }

    private func requestRename(_ thread: AgentThread) {
        guard !sessions.isOpening, integrations.canRename(thread) else { return }
        integrations.actionError = nil
        threadToRename = thread
        renamedTitle = thread.title
        showingRename = true
    }
}
