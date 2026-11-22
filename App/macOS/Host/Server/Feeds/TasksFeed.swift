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
    private let queue: PromptQueue
    private let pullRequests: PullRequestTracker
    /// Resolving a task's project and checkouts reads Git metadata from disk,
    /// so results are cached until the set of projects changes.
    private var projects: [String: Workspace?] = [:]
    /// Agent background session ID → its project, cached the same way.
    private var backgroundProjects: [String: Workspace?] = [:]
    /// Folder path → the checkout it's in, if any.
    private var checkouts: [String: TaskCheckout?] = [:]
    /// The repositories of the checkouts found, whose worktrees are watched:
    /// one made, moved or removed can change where a folder is.
    private var repositories: Set<URL> = []
    private var watchedRepositories: Set<URL> = []
    private var worktreeWatcher: FileSystemWatcher?
    private let worktreeChanges = WorktreeChanges()
    /// Project → the main checkouts of the repositories its folders are, for one pass.
    private var projectRepositories: [UUID: Set<String>] = [:]
    private var projectsSignature: [UUID: [String]] = [:]
    private var observation: Task<Void, Never>?
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    init(
        integrations: AgentIntegrationStore, sessions: TaskSessionController, workspaces: WorkspaceStore,
        orchestrator: Orchestrator, queue: PromptQueue, pullRequests: PullRequestTracker
    ) {
        self.integrations = integrations
        self.sessions = sessions
        self.workspaces = workspaces
        self.orchestrator = orchestrator
        self.queue = queue
        self.pullRequests = pullRequests
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

    func refreshPullRequests(taskID: String? = nil) {
        invalidateProjectsIfNeeded()
        let threads = integrations.visibleThreads(matching: "")
        let subagents = Dictionary(grouping: threads.filter { $0.parentID != nil }) { $0.parentID ?? "" }
        let scope = taskID.map { id in threads.filter { $0.id == id } } ?? threads
        // Record any branch and command changes the feed hasn't published yet.
        for thread in scope {
            let edits = mergedEdits(of: thread, subagents: descendants(of: thread.id, in: subagents))
            let checkouts = checkouts(of: thread, edits: edits, in: project(for: thread))
            _ = trackPullRequests(for: thread, edits: edits, checkouts: checkouts)
        }
        let taskIDs = taskID.map { Set([$0]) } ?? Set(scope.map(\.id))
        pullRequests.refresh(taskIDs: taskIDs, includeSettled: taskID != nil)
    }

    /// The latest state, reading through any change not yet published.
    func snapshot() -> WireTasksSnapshot {
        invalidateProjectsIfNeeded()
        _ = worktreeChanges.count
        let withWorkingDescendants = orchestrator.sessionsWithWorkingDescendants()
        let threads = integrations.visibleThreads(matching: "")
        let subagents = Dictionary(grouping: threads.filter { $0.parentID != nil }) { $0.parentID ?? "" }
        let backgroundSessions = backgroundSessionsByProject()
        return WireTasksSnapshot(
            tasks: threads.map {
                wireTask($0, subagents: descendants(of: $0.id, in: subagents), hasWorkingDescendants: withWorkingDescendants.contains($0.id))
            },
            workspaces: workspaces.workspaces.map { wireWorkspace($0, backgroundSessions: backgroundSessions[$0.id] ?? []) },
            providers: integrations.providers.map { provider in
                WireProvider(
                    provider: provider,
                    isAvailable: integrations.availableProviders.contains(provider),
                    error: integrations.errors[provider],
                    models: integrations.models[provider],
                    defaultSettings: defaultSettings(for: provider),
                    deletionMessage: integrations.deletionMessage(for: provider)
                )
            },
            isRefreshing: integrations.isRefreshing,
            snoozeDuration: integrations.defaultSnooze
        )
    }

    private func wireTask(_ thread: AgentThread, subagents: [AgentThread], hasWorkingDescendants: Bool) -> WireTask {
        var menu = sessions.menuState(for: thread)
        // Stopping a session stops everything working for it, so it can be stopped while only they work.
        if hasWorkingDescendants { menu.allowed.insert(.interrupt) }
        let project = project(for: thread)
        let edits = mergedEdits(of: thread, subagents: subagents)
        let checkouts = checkouts(of: thread, edits: edits, in: project)
        let isSettled = integrations.settledThreadIDs.contains(thread.id)
        return WireTask(
            id: thread.id,
            title: thread.title,
            provider: thread.provider,
            // An agent waiting on a request the host showed, such as for a
            // secret, still reports it's working.
            status: integrations.isWaitingOnHost(thread.id) ? .waiting : thread.status,
            // A task in a linked worktree is named for its project, not the worktree's folder.
            projectName: project?.name ?? thread.projectName,
            path: thread.directory,
            directory: abbreviated(thread.directory),
            workspaceID: project?.id,
            updatedAt: thread.updatedAt,
            hasUnreadResult: thread.hasUnreadResult,
            isSettled: isSettled,
            snoozedUntil: integrations.snoozedUntil[thread.id],
            supportsDeletion: menu.supportsDeletion,
            actions: menu.allowed,
            model: thread.model,
            reasoningEffort: thread.reasoningEffort,
            isFastMode: thread.isFastMode,
            permissionMode: thread.permissionMode,
            permissionModesNeedingRestart: thread.permissionModesNeedingRestart,
            contextUsage: thread.contextUsage?.wire,
            interactions: integrations.interactions.filter { $0.taskID == thread.id },
            checkout: checkouts.current,
            changedCheckouts: checkouts.changed,
            pullRequests: trackPullRequests(for: thread, edits: edits, checkouts: checkouts),
            origin: thread.sideChatParentID.map(WireTaskOrigin.sideChat) ?? thread.parentID.map(WireTaskOrigin.subagent)
                ?? orchestrator.origin(of: thread),
            queuedPrompt: queue.queuedPrompt(for: thread.id)
        )
    }

    private func descendants(of id: String, in subagents: [String: [AgentThread]]) -> [AgentThread] {
        var found: [AgentThread] = []
        var pending = [id]
        var visited: Set<String> = [id]
        while let current = pending.popLast() {
            for child in subagents[current] ?? [] where visited.insert(child.id).inserted {
                found.append(child)
                pending.append(child.id)
            }
        }
        return found
    }

    private func mergedEdits(of thread: AgentThread, subagents: [AgentThread]) -> AgentEdits {
        var edits = thread.edits ?? AgentEdits()
        for subagent in subagents {
            if let theirs = subagent.edits { edits.merge(theirs) }
        }
        return edits
    }

    private func trackPullRequests(for thread: AgentThread, edits: AgentEdits, checkouts: TaskCheckouts) -> [PullRequest] {
        pullRequests.pullRequests(
            for: thread.id, opened: edits.pullRequests, checkouts: checkouts.changed,
            firstChanges: checkouts.firstChanges, updatedAt: thread.updatedAt,
            isActive: !integrations.settledThreadIDs.contains(thread.id) && thread.updatedAt > .now.addingTimeInterval(-3 * 86_400))
    }

    /// The provider's own defaults, with the permission mode Atrium starts new chats in.
    private func defaultSettings(for provider: AgentProvider) -> TaskStartSettings {
        var settings = integrations.defaultSettings[provider] ?? TaskStartSettings()
        settings.permissionMode = integrations.defaultPermissionMode
        return settings
    }

    private func wireWorkspace(_ workspace: Workspace, backgroundSessions: [WireBackgroundSession]) -> WireWorkspace {
        WireWorkspace(
            id: workspace.id,
            name: workspace.name,
            directory: abbreviated(workspace.directory),
            folders: workspace.folders,
            projectType: workspace.projectTypeRaw,
            projectIcon: workspace.projectType.iconName.isEmpty ? nil : workspace.projectType.iconName,
            customIconKey: workspace.customIconFilename,
            scratchpad: workspace.scratchpadDrafts,
            runningCommandCount: workspace.commands.count(where: \.isRunning),
            backgroundSessions: backgroundSessions
        )
    }

    /// Agents' running background sessions, by the project each belongs to.
    private func backgroundSessionsByProject() -> [UUID: [WireBackgroundSession]] {
        let active = integrations.backgroundSessions
        guard !active.isEmpty else { return [:] }
        let threads = integrations.threads
        let titles = Dictionary(threads.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var byProject: [UUID: [WireBackgroundSession]] = [:]
        for session in active {
            let project = backgroundProjects[session.id] ?? {
                let project = workspaces.workspace(forBackgroundSession: session, threads: threads)
                backgroundProjects[session.id] = .some(project)
                return project
            }()
            guard let project else { continue }
            byProject[project.id, default: []].append(WireBackgroundSession(
                id: session.id,
                provider: session.provider,
                taskID: session.taskID,
                taskTitle: titles[session.taskID] ?? "",
                title: session.title,
                command: session.command,
                directory: session.directory,
                startedAt: session.startedAt,
                hasOutput: session.hasOutput
            ))
        }
        return byProject
    }

    private func project(for thread: AgentThread) -> Workspace? {
        let key = (thread.projectDirectory ?? "") + "\n" + thread.directory
        if let cached = projects[key] { return cached }
        let workspace = workspaces.workspace(for: thread)
        projects[key] = .some(workspace)
        return workspace
    }

    private typealias TaskCheckouts = (current: TaskCheckout?, changed: [TaskCheckout], firstChanges: [URL: Date])

    /// The checkouts of its project a task changed files in, the most recently
    /// changed first and one for each repository, its subagents' edits
    /// included; and the one it works in now: the last it changed, or else the
    /// one its commands last ran in, or else its own folder's; and when it
    /// first changed files in each repository, as far as its edits go back.
    /// Changes to repositories that aren't one of its project's folders, or to
    /// files outside any, are left out.
    private func checkouts(of thread: AgentThread, edits: AgentEdits, in project: Workspace?) -> TaskCheckouts {
        let repositories = project.map(repositories(of:)) ?? []
        func inProject(_ checkout: TaskCheckout) -> Bool {
            repositories.contains(checkout.repository.filePath)
        }
        var changed: [TaskCheckout] = []
        var firstChanges: [URL: Date] = [:]
        for path in edits.newestFirst {
            guard let date = edits.folders[path], let checkout = checkout(containing: path, lastUsed: date), inProject(checkout) else { continue }
            firstChanges[checkout.repository] = min(firstChanges[checkout.repository] ?? date, date)
            if !changed.contains(where: { $0.repository == checkout.repository }) { changed.append(checkout) }
        }
        let current = changed.first
            ?? thread.currentDirectory.flatMap { checkout(containing: $0, lastUsed: thread.updatedAt) }.flatMap { inProject($0) ? $0 : nil }
            ?? checkout(containing: thread.directory, lastUsed: thread.updatedAt)
        return (current, changed, firstChanges)
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
        backgroundProjects.removeAll()
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

    /// The main checkouts of the repositories a project's folders are.
    private func repositories(of project: Workspace) -> Set<String> {
        if let cached = projectRepositories[project.id] { return cached }
        let repositories = GitCheckout.repositories(of: project.folders)
        projectRepositories[project.id] = repositories
        return repositories
    }

    private func invalidateProjectsIfNeeded() {
        // Read again on every pass, so a folder made a repository since is followed.
        projectRepositories.removeAll()
        let signature = Dictionary(workspaces.workspaces.map { ($0.id, $0.folders) }, uniquingKeysWith: { $1 })
        guard signature != projectsSignature else { return }
        projectsSignature = signature
        projects.removeAll()
        backgroundProjects.removeAll()
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
