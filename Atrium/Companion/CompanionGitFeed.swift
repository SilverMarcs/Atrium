import Foundation

/// Git status for one project, kept current while any companion watches it.
/// The companion acts on one repository at a time; the selection is shared by
/// every connected phone but independent of the Mac inspector's.
@MainActor
final class CompanionGitFeed {
    let workspace: Workspace
    private(set) var status: WireGitStatus?
    var onChange: ((WireGitStatus) -> Void)?

    private var snapshots: [GitRepositoryStatusSnapshot] = []
    private var selectedRepositoryPath: String?
    private var watcher: FileSystemWatcher?
    /// Only the newest refresh may publish; an older one would restore stale state.
    private var generation = 0

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func start() {
        watcher = FileSystemWatcher(url: workspace.effectiveURL) { @Sendable [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        onChange = nil
    }

    func refresh() async {
        generation += 1
        let generation = generation
        let overrides = workspace.inspectorState.git.worktreeOverrides
        let loaded = (try? await GitRepository.shared.statusSnapshots(in: workspace.effectiveURL, worktreeOverrides: overrides))
            .map { GitInspectorModel.collapseWorktreeSiblings($0, overrides: overrides) } ?? []
        guard generation == self.generation else { return }
        snapshots = loaded
        publish()
    }

    func perform(_ action: CompanionGitAction) async throws {
        switch action {
        case .refresh:
            await refresh()
            return
        case .selectRepository(let path):
            selectedRepositoryPath = path
            publish()
            return
        default:
            break
        }
        if snapshots.isEmpty { await refresh() }
        guard let snapshot = selectedSnapshot else {
            throw IntegrationError(message: "This project has no Git repository.")
        }
        do {
            try await Self.run(action, in: snapshot)
        } catch {
            await refresh()
            throw error
        }
        await refresh()
    }

    func diff(path: String, isStaged: Bool) async throws -> String {
        if snapshots.isEmpty { await refresh() }
        guard let snapshot = selectedSnapshot,
              let file = (isStaged ? snapshot.stagedFiles : snapshot.unstagedFiles)
                .first(where: { $0.repositoryRelativePath == path }) else {
            throw IntegrationError(message: "This file no longer has changes.")
        }
        return try await GitRepository.shared.rawDiff(for: GitDiffReference(
            repositoryRootURL: snapshot.repositoryRootURL,
            fileURL: file.fileURL,
            repositoryRelativePath: path,
            stage: isStaged ? .staged : .unstaged,
            kind: file.kind
        ))
    }

    private var selectedSnapshot: GitRepositoryStatusSnapshot? {
        snapshots.first { $0.repositoryRootURL.path == selectedRepositoryPath } ?? snapshots.first
    }

    private func publish() {
        let selected = selectedSnapshot
        selectedRepositoryPath = selected?.repositoryRootURL.path
        let status = WireGitStatus(
            repositories: snapshots.map {
                WireGitRepository(path: $0.repositoryRootURL.path, name: $0.repositoryRootURL.lastPathComponent, branchName: $0.branchName)
            },
            selectedRepositoryPath: selectedRepositoryPath,
            branchName: selected?.branchName,
            localBranches: selected?.localBranches ?? [],
            stagedFiles: selected?.stagedFiles.map(Self.wireFile) ?? [],
            unstagedFiles: selected?.unstagedFiles.map(Self.wireFile) ?? [],
            unpushedCommits: selected?.unpushedCommits.map { WireGitCommit(hash: $0.hash, message: $0.message) } ?? [],
            hasTrackingBranch: selected?.hasTrackingBranch ?? false,
            remoteAheadCount: selected?.remoteAheadCount ?? 0
        )
        guard status != self.status else { return }
        self.status = status
        onChange?(status)
    }

    private static func wireFile(_ file: GitChangedFile) -> WireGitFile {
        WireGitFile(path: file.repositoryRelativePath, kind: file.kind)
    }

    private static func run(_ action: CompanionGitAction, in snapshot: GitRepositoryStatusSnapshot) async throws {
        let repository = GitRepository.shared
        let root = snapshot.repositoryRootURL
        switch action {
        case .refresh, .selectRepository:
            break
        case .stage(let paths):
            try await repository.stage(paths: paths, at: root)
        case .unstage(let paths):
            try await repository.unstage(paths: paths, at: root)
        case .discard(let paths):
            let untracked = Set(snapshot.unstagedFiles.filter { $0.kind == .untracked }.map(\.repositoryRelativePath))
            try await repository.discardChanges(
                trackedPaths: paths.filter { !untracked.contains($0) },
                untrackedPaths: paths.filter { untracked.contains($0) },
                at: root
            )
        case .stageAll:
            let paths = snapshot.unstagedFiles.map(\.repositoryRelativePath)
            if !paths.isEmpty { try await repository.stage(paths: paths, at: root) }
        case .unstageAll:
            let paths = snapshot.stagedFiles.map(\.repositoryRelativePath)
            if !paths.isEmpty { try await repository.unstage(paths: paths, at: root) }
        case .discardAll:
            try await repository.discardAllChanges(at: root)
        case .commit(let message):
            try await repository.commit(message: message, at: root)
        case .push:
            // Matches the inspector: publishing sets the upstream when there isn't one yet.
            if let branch = snapshot.branchName {
                try await repository.pushSetUpstream(branch: branch, at: root)
            } else {
                try await repository.push(at: root)
            }
        case .pull:
            try await repository.pull(at: root)
        case .fetch:
            try await repository.fetch(at: root)
        case .switchBranch(let name):
            try await repository.switchBranch(to: name, at: root)
        case .createBranch(let name):
            try await repository.createBranch(named: name, at: root)
        }
    }
}
