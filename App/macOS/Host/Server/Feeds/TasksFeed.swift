import AtriumProtocol
import Foundation
import Observation

/// The host's tasks, projects and agents as one `WireTasksSnapshot`.
/// Observation tracks exactly what the snapshot reads, so any change a task
/// list would show (status, titles, settling, projects, commands running)
/// produces one new snapshot; bursts are coalesced before they're published.
@MainActor
final class TasksFeed: TopicFeed {
    private(set) var current: HostEvent?

    private let integrations: AgentIntegrationStore
    private let sessions: TaskSessionController
    private let workspaces: WorkspaceStore
    private let orchestrator: Orchestrator
    /// Resolving a task's project and checkouts reads Git metadata from disk,
    /// so results are cached until the set of projects changes.
    private var projects: [String: Workspace?] = [:]
    /// Folder path → the checkout it's in, if any.
    private var checkouts: [String: TaskCheckout?] = [:]
    /// The repositories of the checkouts found, whose worktrees are watched:
    /// one made, moved or removed can change where a folder is.
    private var repositories: Set<URL> = []
    private var watchedRepositories: Set<URL> = []
    private var worktreeWatcher: FileSystemWatcher?
    private let worktreeChanges = WorktreeChanges()
    private var projectsSignature: [UUID: String] = [:]
    private var observation: Task<Void, Never>?
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    init(integrations: AgentIntegrationStore, sessions: TaskSessionController, workspaces: WorkspaceStore, orchestrator: Orchestrator) {
        self.integrations = integrations
        self.sessions = sessions
        self.workspaces = workspaces
        self.orchestrator = orchestrator
    }

    func start(publish: @escaping (HostEvent) -> Void) {
        observation?.cancel()
        observation = Task { [weak self] in
            let snapshots = Observations { [weak self] in self?.snapshot() }
            for await snapshot in snapshots {
                guard let self, let snapshot, !Task.isCancelled else { return }
                let event = HostEvent.tasks(snapshot)
                self.current = event
                publish(event)
                self.watchWorktrees()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        worktreeWatcher?.stop()
        worktreeWatcher = nil
        watchedRepositories = []
    }

    /// The latest state, reading through any change not yet published.
    func snapshot() -> WireTasksSnapshot {
        invalidateProjectsIfNeeded()
        _ = worktreeChanges.count
        let withWorkingDescendants = orchestrator.sessionsWithWorkingDescendants()
        let threads = integrations.visibleThreads(matching: "")
        let subagents = Dictionary(grouping: threads.filter { $0.parentID != nil }) { $0.parentID ?? "" }
        return WireTasksSnapshot(
            tasks: threads.map {
                wireTask($0, subagents: subagents[$0.id] ?? [], hasWorkingDescendants: withWorkingDescendants.contains($0.id))
            },
            workspaces: workspaces.workspaces.map(wireWorkspace),
            providers: integrations.providers.map { provider in
                WireProvider(
                    provider: provider,
                    isAvailable: integrations.availableProviders.contains(provider),
                    error: integrations.errors[provider],
                    models: integrations.models[provider],
                    defaultSettings: integrations.defaultSettings[provider],
                    deletionMessage: integrations.deletionMessage(for: provider)
                )
            },
            isRefreshing: integrations.isRefreshing
        )
    }

    private func wireTask(_ thread: AgentThread, subagents: [AgentThread], hasWorkingDescendants: Bool) -> WireTask {
        var menu = sessions.menuState(for: thread)
        // Stopping a session stops everything working for it, so it can be stopped while only they work.
        if hasWorkingDescendants { menu.allowed.insert(.interrupt) }
        let project = project(for: thread)
        let checkouts = checkouts(of: thread, subagents: subagents, in: project)
        return WireTask(
            id: thread.id,
            title: thread.title,
            provider: thread.provider,
            status: thread.status,
            // A task in a linked worktree is named for its project, not the worktree's folder.
            projectName: project?.name ?? thread.projectName,
            path: thread.directory,
            directory: abbreviated(thread.directory),
            workspaceID: project?.id,
            updatedAt: thread.updatedAt,
            hasUnreadResult: thread.hasUnreadResult,
            isSettled: integrations.settledThreadIDs.contains(thread.id),
            snoozedUntil: integrations.snoozedUntil[thread.id],
            supportsDeletion: menu.supportsDeletion,
            actions: menu.allowed,
            model: thread.model,
            reasoningEffort: thread.reasoningEffort,
            isFastMode: thread.isFastMode,
            contextUsedPercent: thread.contextUsage?.usedPercent,
            interactions: integrations.interactions.filter { $0.taskID == thread.id },
            checkout: checkouts.current,
            changedCheckouts: checkouts.changed,
            origin: thread.sideChatParentID.map(WireTaskOrigin.sideChat) ?? thread.parentID.map(WireTaskOrigin.subagent)
                ?? orchestrator.origin(of: thread)
        )
    }

    private func wireWorkspace(_ workspace: Workspace) -> WireWorkspace {
        WireWorkspace(
            id: workspace.id,
            name: workspace.name,
            path: workspace.directory,
            directory: abbreviated(workspace.directory),
            projectType: workspace.projectTypeRaw,
            projectIcon: workspace.projectType.iconName.isEmpty ? nil : workspace.projectType.iconName,
            customIconKey: workspace.customIconFilename,
            scratchpad: workspace.scratchPad,
            hasRunningCommand: workspace.commands.contains { $0.isRunning }
        )
    }

    private func project(for thread: AgentThread) -> Workspace? {
        let key = (thread.projectDirectory ?? "") + "\n" + thread.directory
        if let cached = projects[key] { return cached }
        let workspace = workspaces.workspace(for: thread)
        projects[key] = .some(workspace)
        return workspace
    }

    /// The checkouts of its project a task changed files in, the most recently
    /// changed first and one for each repository, its subagents' edits
    /// included; and the one it works in now: the last it changed, or else the
    /// one its commands last ran in, or else its own folder's. Changes to
    /// other projects' repositories or to files outside any are left out.
    private func checkouts(of thread: AgentThread, subagents: [AgentThread], in project: Workspace?)
        -> (current: TaskCheckout?, changed: [TaskCheckout]) {
        let folder = project.map { URL(filePath: $0.directory, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath() }
        func inProject(_ checkout: TaskCheckout) -> Bool {
            folder.map { $0.contains(checkout.repository) || checkout.repository.contains($0) } ?? false
        }
        var edits = thread.edits ?? AgentEdits()
        for subagent in subagents {
            if let theirs = subagent.edits { edits.merge(theirs) }
        }
        var changed: [TaskCheckout] = []
        for path in edits.newestFirst {
            guard let checkout = checkout(containing: path, lastUsed: edits.folders[path]), inProject(checkout),
                  !changed.contains(where: { $0.repository == checkout.repository }) else { continue }
            changed.append(checkout)
        }
        let current = changed.first
            ?? thread.currentDirectory.flatMap { checkout(containing: $0, lastUsed: thread.updatedAt) }.flatMap { inProject($0) ? $0 : nil }
            ?? checkout(containing: thread.directory, lastUsed: thread.updatedAt)
        return (current, changed)
    }

    /// The checkout a folder the task used is in now: where its worktree
    /// went if it has moved since, or the main checkout if it was removed.
    private func checkout(containing path: String, lastUsed: Date?) -> TaskCheckout? {
        if let cached = checkouts[path] { return cached }
        let checkout = GitCheckout(locating: URL(filePath: path, directoryHint: .isDirectory), lastUsed: lastUsed).map {
            TaskCheckout(repository: $0.mainCheckoutURL, worktree: $0.linkedWorktreeURL)
        }
        checkouts[path] = .some(checkout)
        if let checkout { repositories.insert(checkout.repository) }
        return checkout
    }

    /// Watches the admin directories Git keeps for the repositories' linked
    /// worktrees, which change when one is made, moved or removed, to find
    /// the tasks' checkouts again.
    private func watchWorktrees() {
        guard repositories != watchedRepositories else { return }
        watchedRepositories = repositories
        worktreeWatcher?.stop()
        worktreeWatcher = repositories.isEmpty ? nil : FileSystemWatcher(
            urls: repositories.map { $0.appending(path: ".git", directoryHint: .isDirectory) }
        ) { [weak self] paths in
            guard paths.contains(where: Self.changesWorktree) else { return }
            Task { @MainActor in self?.worktreesChanged() }
        }
    }

    private func worktreesChanged() {
        projects.removeAll()
        checkouts.removeAll()
        repositories.removeAll()
        worktreeChanges.count += 1
    }

    /// Whether a change in a `.git` folder adds, moves or removes a linked
    /// worktree: its admin directory comes or goes, or its `gitdir` file,
    /// naming where the worktree is, is written.
    private nonisolated static func changesWorktree(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/worktrees/") else { return path.hasSuffix("/.git/worktrees") }
        let inside = path[range.upperBound...]
        return !inside.contains("/") || inside.hasSuffix("/gitdir")
    }

    private func invalidateProjectsIfNeeded() {
        let signature = Dictionary(workspaces.workspaces.map { ($0.id, $0.directory) }, uniquingKeysWith: { $1 })
        guard signature != projectsSignature else { return }
        projectsSignature = signature
        projects.removeAll()
        checkouts.removeAll()
        repositories.removeAll()
    }

    private func abbreviated(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Counts the changes to the watched repositories' worktrees, so the tasks
/// are listed again when one is made, moved or removed.
@MainActor
@Observable
private final class WorktreeChanges {
    var count = 0
}
