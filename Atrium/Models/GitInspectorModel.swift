import Foundation

@Observable @MainActor
final class GitInspectorModel {
    private(set) var snapshots: [GitRepositoryStatusSnapshot] = []
    private(set) var isLoading = false
    private(set) var hasCompletedInitialScan = false
    private(set) var activeTaskCount = 0
    var errorMessage: String?
    var successMessage: String?

    var isBusy: Bool { activeTaskCount > 0 }

    var hasChanges: Bool {
        snapshots.contains { !$0.stagedFiles.isEmpty || !$0.unstagedFiles.isEmpty }
    }

    func refresh(directoryURL: URL, worktreeOverrides: [URL: URL] = [:]) async {
        isLoading = snapshots.isEmpty
        errorMessage = nil

        do {
            let newSnapshots = Self.collapseWorktreeSiblings(
                try await GitRepository.shared.statusSnapshots(in: directoryURL, worktreeOverrides: worktreeOverrides),
                overrides: worktreeOverrides
            )
            if newSnapshots != snapshots {
                snapshots = newSnapshots
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        hasCompletedInitialScan = true
    }

    func stage(files: [GitChangedFile], snapshot: GitRepositoryStatusSnapshot) async {
        let paths = files.map(\.repositoryRelativePath)
        guard !paths.isEmpty else { return }
        await perform {
            try await GitRepository.shared.stage(paths: paths, at: snapshot.repositoryRootURL)
        }
    }

    func unstage(files: [GitChangedFile], snapshot: GitRepositoryStatusSnapshot) async {
        let paths = files.map(\.repositoryRelativePath)
        guard !paths.isEmpty else { return }
        await perform {
            try await GitRepository.shared.unstage(paths: paths, at: snapshot.repositoryRootURL)
        }
    }

    func stageAll(snapshot: GitRepositoryStatusSnapshot) async {
        let paths = snapshot.unstagedFiles.map(\.repositoryRelativePath)
        guard !paths.isEmpty else { return }
        await perform {
            try await GitRepository.shared.stage(paths: paths, at: snapshot.repositoryRootURL)
        }
    }

    func unstageAll(snapshot: GitRepositoryStatusSnapshot) async {
        let paths = snapshot.stagedFiles.map(\.repositoryRelativePath)
        guard !paths.isEmpty else { return }
        await perform {
            try await GitRepository.shared.unstage(paths: paths, at: snapshot.repositoryRootURL)
        }
    }

    func discardChanges(files: [GitChangedFile], snapshot: GitRepositoryStatusSnapshot) async {
        let tracked = files.filter { $0.kind != .untracked }.map(\.repositoryRelativePath)
        let untracked = files.filter { $0.kind == .untracked }.map(\.repositoryRelativePath)
        await perform {
            try await GitRepository.shared.discardChanges(trackedPaths: tracked, untrackedPaths: untracked, at: snapshot.repositoryRootURL)
        }
    }

    func discardAllChanges(snapshot: GitRepositoryStatusSnapshot) async {
        await perform {
            try await GitRepository.shared.discardAllChanges(at: snapshot.repositoryRootURL)
        }
    }

    func commit(message: String, snapshot: GitRepositoryStatusSnapshot) async {
        await perform(successLabel: "Committed successfully") {
            try await GitRepository.shared.commit(message: message, at: snapshot.repositoryRootURL)
        }
    }

    func push(snapshot: GitRepositoryStatusSnapshot) async {
        await perform(successLabel: "Pushed successfully") {
            if let branch = snapshot.branchName {
                try await GitRepository.shared.pushSetUpstream(branch: branch, at: snapshot.repositoryRootURL)
            } else {
                try await GitRepository.shared.push(at: snapshot.repositoryRootURL)
            }
        }
    }

    func pushSetUpstream(branch: String, snapshot: GitRepositoryStatusSnapshot) async {
        await perform(successLabel: "Branch published successfully") {
            try await GitRepository.shared.pushSetUpstream(branch: branch, at: snapshot.repositoryRootURL)
        }
    }

    func remoteURL(snapshot: GitRepositoryStatusSnapshot) async -> String? {
        do {
            return try await GitRepository.shared.remoteURL(at: snapshot.repositoryRootURL)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func pull(snapshot: GitRepositoryStatusSnapshot) async {
        await perform(successLabel: "Pulled successfully") {
            try await GitRepository.shared.pull(at: snapshot.repositoryRootURL)
        }
    }

    func pullPreservingChanges(snapshot: GitRepositoryStatusSnapshot) async -> PullPreservingResult? {
        activeTaskCount += 1
        defer { activeTaskCount -= 1 }
        errorMessage = nil
        successMessage = nil
        do {
            let result = try await GitRepository.shared.pullPreservingChanges(at: snapshot.repositoryRootURL)
            if result == .clean {
                successMessage = "Pulled with local changes preserved"
            }
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func syncWithBranch(_ branch: String, snapshot: GitRepositoryStatusSnapshot) async {
        // Fetch first to ensure we have latest remote state
        try? await GitRepository.shared.fetch(at: snapshot.repositoryRootURL)
        await perform(successLabel: "Rebased onto \(branch)") {
            try await GitRepository.shared.rebaseBranch("origin/\(branch)", at: snapshot.repositoryRootURL)
        }
    }

    func syncWithRemote(snapshot: GitRepositoryStatusSnapshot) async {
        await perform(successLabel: "Synced with remote") {
            try await GitRepository.shared.pullRebase(at: snapshot.repositoryRootURL)
        }
    }

    func fetch(snapshot: GitRepositoryStatusSnapshot) async {
        await perform {
            try await GitRepository.shared.fetch(at: snapshot.mainRepositoryURL)
        }
    }

    /// Throttled and silent — for automatic refreshes (workspace/tab switches,
    /// branch changes). Explicit user refresh uses `fetch(snapshot:)`.
    func fetchIfStale(snapshot: GitRepositoryStatusSnapshot) async {
        try? await GitRepository.shared.fetchIfStale(at: snapshot.mainRepositoryURL)
    }

    func commitLog(snapshot: GitRepositoryStatusSnapshot, limit: Int = 200) async -> [GitLogEntry] {
        do {
            return try await GitRepository.shared.commitLog(at: snapshot.repositoryRootURL, limit: limit)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func switchBranch(to branch: String, at repositoryRootURL: URL) async {
        await perform(successLabel: "Switched to \(branch)") {
            try await GitRepository.shared.switchBranch(to: branch, at: repositoryRootURL)
        }
    }

    func createBranch(named name: String, snapshot: GitRepositoryStatusSnapshot) async {
        await perform(successLabel: "Created branch \(name)") {
            try await GitRepository.shared.createBranch(named: name, at: snapshot.repositoryRootURL)
        }
    }

    func stashAndSwitch(to branch: String, at repositoryRootURL: URL) async {
        let stashed = await perform {
            try await GitRepository.shared.stashAll(at: repositoryRootURL)
        }
        guard stashed else { return }
        await perform {
            try await GitRepository.shared.switchBranch(to: branch, at: repositoryRootURL)
        }
    }

    func stashAll(message: String, snapshot: GitRepositoryStatusSnapshot) async {
        await perform(successLabel: "Changes stashed") {
            try await GitRepository.shared.stashAll(message: message, at: snapshot.repositoryRootURL)
        }
    }

    func undoLastCommit(snapshot: GitRepositoryStatusSnapshot) async {
        await perform(successLabel: "Last commit undone") {
            try await GitRepository.shared.undoLastCommit(at: snapshot.repositoryRootURL)
        }
    }

    func amendCommitMessage(_ message: String, snapshot: GitRepositoryStatusSnapshot) async {
        await perform(successLabel: "Commit renamed") {
            try await GitRepository.shared.amendCommitMessage(message, at: snapshot.repositoryRootURL)
        }
    }

    func canApplyStashCleanly(snapshot: GitRepositoryStatusSnapshot) async -> Bool {
        await GitRepository.shared.canStashApplyCleanly(at: snapshot.repositoryRootURL)
    }

    func applyLatestStash(snapshot: GitRepositoryStatusSnapshot) async {
        await perform(successLabel: "Stash applied") {
            try await GitRepository.shared.stashPop(at: snapshot.repositoryRootURL)
        }
    }

    func branches(snapshot: GitRepositoryStatusSnapshot) async -> [GitBranchInfo] {
        do {
            return try await GitRepository.shared.allBranchesDetailed(at: snapshot.repositoryRootURL)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func syncBranchWithUpstream(_ branch: GitBranchInfo, snapshot: GitRepositoryStatusSnapshot) async {
        guard let upstream = branch.upstream else {
            errorMessage = "Branch '\(branch.name)' does not have an upstream tracking branch configured."
            return
        }

        activeTaskCount += 1
        defer { activeTaskCount -= 1 }
        errorMessage = nil
        successMessage = nil

        do {
            let result = try await GitRepository.shared.syncBranchWithUpstream(
                localBranch: branch.name,
                upstreamBranch: upstream,
                at: snapshot.repositoryRootURL
            )
            switch result {
            case .alreadyUpToDate:
                successMessage = "'\(branch.name)' is already up to date with upstream."
            case .synced:
                successMessage = "Synced '\(branch.name)' with upstream successfully."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteBranch(_ name: String, force: Bool, snapshot: GitRepositoryStatusSnapshot) async -> Bool {
        await perform(successLabel: "Deleted branch \(name)") {
            try await GitRepository.shared.deleteBranch(name, force: force, at: snapshot.repositoryRootURL)
        }
    }

    func stashList(snapshot: GitRepositoryStatusSnapshot) async -> [GitStashEntry] {
        do {
            return try await GitRepository.shared.stashList(at: snapshot.repositoryRootURL)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func dropStash(index: Int, snapshot: GitRepositoryStatusSnapshot) async -> Bool {
        await perform(successLabel: "Stash dropped") {
            try await GitRepository.shared.dropStash(index: index, at: snapshot.repositoryRootURL)
        }
    }

    func applyStash(index: Int, snapshot: GitRepositoryStatusSnapshot) async {
        await perform(successLabel: "Stash applied") {
            try await GitRepository.shared.applyStash(index: index, at: snapshot.repositoryRootURL)
        }
    }

    func stashChangedFiles(index: Int, snapshot: GitRepositoryStatusSnapshot) async -> [GitChangedFile] {
        do {
            return try await GitRepository.shared.stashChangedFiles(index: index, at: snapshot.repositoryRootURL)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func initializeRepository(at directoryURL: URL) async {
        await perform(successLabel: "Repository initialized") {
            try await GitRepository.shared.initializeRepository(at: directoryURL)
        }
    }

    // MARK: - Private

    /// A linked worktree discovered alongside its repository's main checkout (e.g.
    /// a worktree folder inside the workspace) is the same repository seen twice.
    /// The inspector shows one entry per repository: the overridden context when
    /// set, otherwise the main checkout — switching between them is the branch
    /// picker's job, not the repo picker's.
    private static func collapseWorktreeSiblings(
        _ snapshots: [GitRepositoryStatusSnapshot],
        overrides: [URL: URL]
    ) -> [GitRepositoryStatusSnapshot] {
        var byRepo: [URL: GitRepositoryStatusSnapshot] = [:]
        for snapshot in snapshots {
            let key = snapshot.mainRepositoryURL
            guard let existing = byRepo[key] else {
                byRepo[key] = snapshot
                continue
            }
            if let overrideURL = overrides[key]?.standardizedFileURL.resolvingSymlinksInPath() {
                if snapshot.repositoryRootURL == overrideURL {
                    byRepo[key] = snapshot
                }
            } else if existing.isLinkedWorktree && !snapshot.isLinkedWorktree {
                byRepo[key] = snapshot
            }
        }
        return byRepo.values.sorted { $0.mainRepositoryURL.path < $1.mainRepositoryURL.path }
    }

    @discardableResult
    private func perform(successLabel: String? = nil, _ operation: () async throws -> Void) async -> Bool {
        activeTaskCount += 1
        defer { activeTaskCount -= 1 }
        errorMessage = nil
        successMessage = nil
        do {
            try await operation()
            if let successLabel {
                successMessage = successLabel
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
