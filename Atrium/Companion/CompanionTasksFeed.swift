import Foundation
import Observation

/// Mirrors the sidebar as a `WireTasksSnapshot` and reports each change.
/// Observation tracks exactly what the snapshot reads, so any change the
/// sidebar would show (status, titles, settling, projects, commands running)
/// produces one new snapshot; bursts are coalesced before they're sent.
@MainActor
final class CompanionTasksFeed {
    private let integrations: AgentIntegrationStore
    private let sessions: TaskSessionController
    private let workspaces: WorkspaceStore
    /// Resolving a task's project can read git metadata from disk, so results are
    /// cached until the set of projects changes.
    private var projectIDs: [String: UUID?] = [:]
    private var projectsSignature: [UUID: String] = [:]
    private var observation: Task<Void, Never>?
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    init(integrations: AgentIntegrationStore, sessions: TaskSessionController, workspaces: WorkspaceStore) {
        self.integrations = integrations
        self.sessions = sessions
        self.workspaces = workspaces
    }

    func start(onChange: @escaping (WireTasksSnapshot) -> Void) {
        observation?.cancel()
        observation = Task { [weak self] in
            let snapshots = Observations { [weak self] in self?.snapshot() }
            for await snapshot in snapshots {
                guard let snapshot, !Task.isCancelled else { return }
                onChange(snapshot)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    func snapshot() -> WireTasksSnapshot {
        invalidateProjectsIfNeeded()
        let tasks = integrations.visibleThreads(matching: "").map(wireTask)
        return WireTasksSnapshot(
            tasks: tasks,
            workspaces: workspaces.workspaces.map(wireWorkspace),
            providers: integrations.providers.map { provider in
                WireProvider(
                    provider: provider,
                    isEnabled: integrations.enabledProviders.contains(provider),
                    error: integrations.errors[provider],
                    models: integrations.models[provider]
                )
            }
        )
    }

    private func wireTask(_ thread: AgentThread) -> WireTask {
        let menu = sessions.menuState(for: thread)
        return WireTask(
            id: thread.id,
            title: thread.title,
            provider: thread.provider,
            status: thread.status,
            projectName: thread.projectName,
            directory: abbreviated(thread.directory),
            workspaceID: projectID(for: thread),
            updatedAt: thread.updatedAt,
            hasUnreadResult: thread.hasUnreadResult,
            isSettled: integrations.settledThreadIDs.contains(thread.id),
            snoozedUntil: integrations.snoozedUntil[thread.id],
            supportsDeletion: menu.supportsDeletion,
            actions: menu.allowed,
            model: thread.model,
            reasoningEffort: thread.reasoningEffort,
            isFastMode: thread.isFastMode
        )
    }

    private func wireWorkspace(_ workspace: Workspace) -> WireWorkspace {
        WireWorkspace(
            id: workspace.id,
            name: workspace.name,
            directory: abbreviated(workspace.directory),
            projectIcon: workspace.projectType.iconName.isEmpty ? nil : workspace.projectType.iconName,
            customIconKey: workspace.customIconFilename,
            scratchpad: workspace.scratchPad,
            hasRunningCommand: workspace.commands.contains { $0.isRunning }
        )
    }

    private func projectID(for thread: AgentThread) -> UUID? {
        let key = (thread.projectDirectory ?? "") + "\n" + thread.directory
        if let cached = projectIDs[key] { return cached }
        let id = workspaces.workspace(for: thread)?.id
        projectIDs[key] = id
        return id
    }

    private func invalidateProjectsIfNeeded() {
        let signature = Dictionary(workspaces.workspaces.map { ($0.id, $0.directory) }, uniquingKeysWith: { $1 })
        guard signature != projectsSignature else { return }
        projectsSignature = signature
        projectIDs.removeAll()
    }

    private func abbreviated(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
