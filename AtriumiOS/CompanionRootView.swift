import AtriumClient
import SwiftUI

struct CompanionRootView: View {
    @Environment(HostDirectory.self) private var hosts
    @State private var dictationSettings = DictationSettings()
    @State private var selectedTask: TaskRef?
    /// The task the detail column keeps showing once going back on iPhone has
    /// cleared the selection. See `detailTask`.
    @State private var lastSelectedTask: TaskRef?
    @State private var detailPath: [Route] = []
    @State private var showingHosts = false

    var body: some View {
        Group {
            if !hosts.hosts.isEmpty {
                // Tasks in the sidebar and the selected task in the detail column on
                // iPad; on iPhone the split view collapses into a single stack.
                NavigationSplitView {
                    TasksScreen(selection: $selectedTask) { showingHosts = true }
                        .navigationSplitViewColumnWidth(min: 300, ideal: 340)
                } detail: {
                    NavigationStack(path: $detailPath) {
                        Group {
                            if let detailTask {
                                TaskDetailScreen(ref: detailTask)
                            } else {
                                ContentUnavailableView("No Task Selected", systemImage: "sidebar.left")
                            }
                        }
                        .navigationDestination(for: Route.self) { route in
                            RouteDestination(route: route)
                        }
                    }
                    // Delegated sessions open over the session that asked, so Back returns to it.
                    .environment(\.openDelegatedTask) { ref in detailPath.append(.task(ref)) }
                }
            } else {
                NavigationStack {
                    PairingScreen()
                }
            }
        }
        .environment(dictationSettings)
        .onOpenURL { url in hosts.handle(url) }
        .onChange(of: selectedTask) { _, ref in
            if let ref { lastSelectedTask = ref }
            detailPath = []
        }
        .onChange(of: hosts.pendingTask, initial: true) { _, ref in
            guard let ref else { return }
            selectedTask = ref
            detailPath = []
            hosts.pendingTask = nil
            #if DEBUG
            if let route = Route.debugLaunch(for: ref, in: hosts) {
                // After the selection change has reset the path.
                Task { detailPath = [route] }
            }
            #endif
        }
        .onChange(of: hosts.hosts.map(\.id)) { _, ids in
            if let selected = selectedTask, !ids.contains(selected.hostID) { selectedTask = nil }
            if let last = lastSelectedTask, !ids.contains(last.hostID) { lastSelectedTask = nil }
        }
        .sheet(isPresented: $showingHosts) {
            HostsSheet()
                .environment(dictationSettings)
        }
        .alert(
            "Couldn’t Complete Action",
            isPresented: Binding(get: { hosts.actionError != nil }, set: { if !$0 { hosts.actionError = nil } })
        ) {
            Button("OK") { hosts.actionError = nil }
        } message: {
            Text(hosts.actionError ?? "")
        }
    }

    /// Going back on iPhone clears the selection, but the detail column keeps
    /// the last task's screen rather than swapping in a placeholder. Opening a
    /// task then updates that screen in place: a screen swapped in while the
    /// collapsed split view pushes the column is attached twice, so its tasks
    /// run twice (subscribing, unsubscribing and resubscribing to the
    /// transcript, and marking it read twice) and its search-field composer is
    /// installed twice, bouncing the bottom bar.
    private var detailTask: TaskRef? {
        selectedTask ?? lastSelectedTask
    }
}

/// The screen a route pushes, in its project on its host.
private struct RouteDestination: View {
    @Environment(HostDirectory.self) private var hosts
    let route: Route

    var body: some View {
        switch route {
        case .sourceControl(let ref):
            if let host = hosts.host(ref.hostID) { SourceControlScreen(host: host, workspaceID: ref.workspaceID) }
        case .fileDiff(let ref, let file, let repository, let isStaged):
            if let host = hosts.host(ref.hostID) {
                FileDiffScreen(host: host, workspaceID: ref.workspaceID, file: file, repository: repository, isStaged: isStaged)
            }
        case .commands(let ref):
            if let host = hosts.host(ref.hostID) { CommandsScreen(host: host, workspaceID: ref.workspaceID) }
        case .files(let ref, let folder):
            if let host = hosts.host(ref.hostID) { FilesScreen(host: host, workspaceID: ref.workspaceID, folder: folder) }
        case .file(let ref, let path, let line):
            if let host = hosts.host(ref.hostID) { FilePreviewScreen(host: host, workspaceID: ref.workspaceID, path: path, line: line) }
        case .search(let ref):
            if let host = hosts.host(ref.hostID) { SearchScreen(host: host, workspaceID: ref.workspaceID) }
        case .task(let ref):
            TaskDetailScreen(ref: ref)
        }
    }
}
