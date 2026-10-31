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
    /// Resolving a task's project and checkout reads Git metadata from disk, so
    /// results are cached until the set of projects changes.
    private var projects: [String: (id: UUID?, checkout: TaskCheckout?)] = [:]
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
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    /// The latest state, reading through any change not yet published.
    func snapshot() -> WireTasksSnapshot {
        invalidateProjectsIfNeeded()
        let origins = orchestrator.origins()
        let delegating = orchestrator.sessionsWithWorkingDelegations()
        return WireTasksSnapshot(
            tasks: integrations.visibleThreads(matching: "").map {
                wireTask($0, origin: origins[$0.id], isDelegating: delegating.contains($0.id))
            },
            workspaces: workspaces.workspaces.map(wireWorkspace),
            providers: integrations.providers.map { provider in
                WireProvider(
                    provider: provider,
                    isEnabled: integrations.enabledProviders.contains(provider),
                    error: integrations.errors[provider],
                    models: integrations.models[provider],
                    defaultSettings: integrations.defaultSettings[provider],
                    deletionMessage: integrations.deletionMessage(for: provider)
                )
            },
            isRefreshing: integrations.isRefreshing
        )
    }

    private func wireTask(_ thread: AgentThread, origin: DelegatedTask.Requester?, isDelegating: Bool) -> WireTask {
        var menu = sessions.menuState(for: thread)
        // Stopping a session stops the work it delegated, so it can be stopped while only that works.
        if isDelegating { menu.allowed.insert(.interrupt) }
        let project = project(for: thread)
        return WireTask(
            id: thread.id,
            title: thread.title,
            provider: thread.provider,
            status: thread.status,
            projectName: thread.projectName,
            directory: abbreviated(thread.directory),
            workspaceID: project.id,
            updatedAt: thread.updatedAt,
            hasUnreadResult: thread.hasUnreadResult,
            isSettled: integrations.settledThreadIDs.contains(thread.id),
            snoozedUntil: integrations.snoozedUntil[thread.id],
            supportsDeletion: menu.supportsDeletion,
            actions: menu.allowed,
            model: thread.model,
            reasoningEffort: thread.reasoningEffort,
            isFastMode: thread.isFastMode,
            interactions: integrations.interactions.filter { $0.taskID == thread.id },
            checkout: project.checkout,
            origin: thread.parentID.map(WireTaskOrigin.subagent) ?? origin.map {
                switch $0 {
                case .session(let id): .session(id)
                case .remote: .chatGPT
                }
            }
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

    private func project(for thread: AgentThread) -> (id: UUID?, checkout: TaskCheckout?) {
        let key = (thread.projectDirectory ?? "") + "\n" + thread.directory
        if let cached = projects[key] { return cached }
        let checkout = GitCheckout(containing: URL(filePath: thread.directory)).map {
            TaskCheckout(repository: $0.mainCheckoutURL, worktree: $0.linkedWorktreeURL)
        }
        let project = (workspaces.workspace(for: thread)?.id, checkout)
        projects[key] = project
        return project
    }

    private func invalidateProjectsIfNeeded() {
        let signature = Dictionary(workspaces.workspaces.map { ($0.id, $0.directory) }, uniquingKeysWith: { $1 })
        guard signature != projectsSignature else { return }
        projectsSignature = signature
        projects.removeAll()
    }

    private func abbreviated(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
