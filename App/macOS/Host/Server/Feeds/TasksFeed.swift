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
    private let taskWorkspaces: TaskWorkspaces
    /// Resolving a task's project reads Git metadata from disk, so results
    /// are cached until the set of projects changes.
    private var projects: [String: Workspace?] = [:]
    /// Agent background session ID → its project, cached the same way.
    private var backgroundProjects: [String: Workspace?] = [:]
    /// Tasks whose agents are in a turn, as status changes reported them.
    private var working: Set<String> = []
    /// Project → the main checkouts of the repositories its folders are, for one pass.
    private var projectRepositories: [UUID: Set<String>] = [:]
    private var projectsSignature: [UUID: [String]] = [:]
    private var observation: Task<Void, Never>?
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    init(
        integrations: AgentIntegrationStore, sessions: TaskSessionController, workspaces: WorkspaceStore,
        orchestrator: Orchestrator, queue: PromptQueue, pullRequests: PullRequestTracker, taskWorkspaces: TaskWorkspaces
    ) {
        self.integrations = integrations
        self.sessions = sessions
        self.workspaces = workspaces
        self.orchestrator = orchestrator
        self.queue = queue
        self.pullRequests = pullRequests
        self.taskWorkspaces = taskWorkspaces
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
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    /// Notes where each task works and the pull requests its commands
    /// opened, as of its latest activity. Tasks that haven't changed are skipped.
    private func recordWork() {
        let threads = integrations.visibleThreads()
        let subagents = Dictionary(grouping: threads.filter { $0.parentID != nil }) { $0.parentID ?? "" }
        for thread in threads {
            let edits = mergedEdits(of: thread, subagents: descendants(of: thread.id, in: subagents))
            pullRequests.noteOpened(edits.pullRequests, by: thread.id)
            guard let project = project(for: thread) else { continue }
            taskWorkspaces.record(
                thread.id, edits: edits, currentDirectory: thread.currentDirectory, updatedAt: thread.updatedAt,
                repositories: repositories(of: project))
        }
    }

    /// Refreshes a task's pull requests when its agent finishes a turn, which
    /// is when it has pushed or opened one. Tasks only seen idle since launch
    /// are left to the refreshes their clients ask for.
    func observe(_ thread: AgentThread) {
        if thread.status.isWorking {
            working.insert(thread.id)
        } else if working.remove(thread.id) != nil {
            // Once the store holds the thread as it is now.
            Task { [weak self] in self?.refreshPullRequests(taskID: thread.id, afterTurn: true) }
        }
    }

    /// Refreshes one opened task's pull requests, settled or not, or else
    /// those of the tasks still active. After a turn, a repository listed in
    /// the last minute isn't listed again.
    func refreshPullRequests(taskID: String? = nil, afterTurn: Bool = false) {
        invalidateProjectsIfNeeded()
        recordWork()
        let threads = integrations.visibleThreads().filter { thread in
            taskID.map { thread.id == $0 } ?? isActive(thread)
        }
        let tasks = Dictionary(threads.map { thread in
            (thread.id, taskWorkspaces.workspaces(of: thread.id, in: project(for: thread).map(repositories(of:)) ?? []))
        }, uniquingKeysWith: { first, _ in first })
        pullRequests.refresh(tasks, includeMerged: taskID != nil && !afterTurn, recentListingsSuffice: afterTurn)
    }

    private func isActive(_ thread: AgentThread) -> Bool {
        !integrations.settledThreadIDs.contains(thread.id) && thread.updatedAt > .now.addingTimeInterval(-3 * 86_400)
    }

    /// The latest state, reading through any change not yet published.
    func snapshot() -> WireTasksSnapshot {
        invalidateProjectsIfNeeded()
        recordWork()
        let withWorkingDescendants = orchestrator.sessionsWithWorkingDescendants()
        let threads = integrations.visibleThreads()
        let backgroundSessions = backgroundSessionsByProject()
        return WireTasksSnapshot(
            tasks: threads.map {
                wireTask($0, hasWorkingDescendants: withWorkingDescendants.contains($0.id))
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

    private func wireTask(_ thread: AgentThread, hasWorkingDescendants: Bool) -> WireTask {
        var (actions, supportsDeletion) = sessions.actions(for: thread)
        // Stopping a session stops everything working for it, so it can be stopped while only they work.
        if hasWorkingDescendants { actions.insert(.interrupt) }
        let project = project(for: thread)
        let checkouts = checkouts(of: thread, in: project)
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
            supportsDeletion: supportsDeletion,
            actions: actions,
            model: thread.model,
            reasoningEffort: thread.reasoningEffort,
            isFastMode: thread.isFastMode,
            permissionMode: thread.permissionMode,
            permissionModesNeedingRestart: thread.permissionModesNeedingRestart,
            contextUsage: thread.contextUsage?.wire,
            interactions: integrations.interactions.filter { $0.taskID == thread.id },
            checkout: checkouts.current,
            changedCheckouts: checkouts.changed,
            pullRequests: pullRequests.pullRequests(for: thread.id, checkouts: checkouts.changed),
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
                startedAt: session.startedAt
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

    /// The checkouts of its project a task worked in, the most recently
    /// used first and one for each repository; and the one it works in now:
    /// the last it worked in, or else the one its commands last ran in, or
    /// else its own folder's.
    private func checkouts(of thread: AgentThread, in project: Workspace?) -> (current: TaskCheckout?, changed: [TaskCheckout]) {
        let repositories = project.map(repositories(of:)) ?? []
        var changed: [TaskCheckout] = []
        for workspace in taskWorkspaces.workspaces(of: thread.id, in: repositories)
        where !changed.contains(where: { $0.repository == workspace.checkout.repository }) {
            changed.append(workspace.checkout)
        }
        let current = changed.first
            ?? thread.currentDirectory.flatMap { taskWorkspaces.checkout(at: $0, lastUsed: thread.updatedAt) }
                .flatMap { repositories.contains($0.repository.filePath) ? $0 : nil }
            ?? taskWorkspaces.checkout(at: thread.directory, lastUsed: thread.updatedAt)
        return (current, changed)
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
    }

    private func abbreviated(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
