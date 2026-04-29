import Foundation

@MainActor
extension GitInspectorState {
    func refresh(directoryURL: URL) async {
        await model.refresh(directoryURL: directoryURL)
    }

    /// Handles state-only actions. View-specific actions (`.commit`, `.showInFileTree`)
    /// are no-ops here and must be dispatched by the calling view.
    func perform(_ action: GitAction, directoryURL: URL) {
        switch action {
        case .stage(let files, let snapshot):
            Task {
                await model.stage(files: files, snapshot: snapshot)
                await refresh(directoryURL: directoryURL)
            }
        case .unstage(let files, let snapshot):
            Task {
                await model.unstage(files: files, snapshot: snapshot)
                await refresh(directoryURL: directoryURL)
            }
        case .stageAll(let snapshot):
            Task {
                await model.stageAll(snapshot: snapshot)
                await refresh(directoryURL: directoryURL)
            }
        case .unstageAll(let snapshot):
            Task {
                await model.unstageAll(snapshot: snapshot)
                await refresh(directoryURL: directoryURL)
            }
        case .discard(let files, let snapshot):
            discardTarget = .files(files, snapshot)
        case .discardAll(let snapshot):
            discardTarget = .all(snapshot)
        case .push(let snapshot):
            Task {
                await model.push(snapshot: snapshot)
                await refresh(directoryURL: directoryURL)
            }
        case .commit, .showInFileTree:
            break
        }
    }

    func switchBranch(to branch: String, directoryURL: URL, snapshot: GitRepositoryStatusSnapshot) {
        if snapshot.isDirty {
            pendingBranchSwitch = branch
        } else {
            Task {
                await model.switchBranch(to: branch, snapshot: snapshot)
                await refresh(directoryURL: directoryURL)
                await fetchAndRefreshQuietly(directoryURL: directoryURL, snapshot: snapshot)
            }
        }
    }

    func confirmStashAndSwitch(directoryURL: URL) {
        guard let branch = pendingBranchSwitch,
              let snapshot = currentSnapshot else { return }
        Task {
            await model.stashAndSwitch(to: branch, snapshot: snapshot)
            await refresh(directoryURL: directoryURL)
            await fetchAndRefreshQuietly(directoryURL: directoryURL, snapshot: snapshot)
        }
    }

    /// Best-effort fetch so the new branch's upstream state reflects reality.
    /// Errors (offline, no remote) are silent — branch switching shouldn't surface them.
    private func fetchAndRefreshQuietly(directoryURL: URL, snapshot: GitRepositoryStatusSnapshot) async {
        try? await GitRepository.shared.fetch(at: snapshot.repositoryRootURL)
        await refresh(directoryURL: directoryURL)
    }

    func confirmStashAll(directoryURL: URL) {
        guard let snapshot = currentSnapshot else { return }
        let message = stashMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        Task {
            await model.stashAll(message: message, snapshot: snapshot)
            stashMessage = ""
            await refresh(directoryURL: directoryURL)
        }
    }

    func applyLatestStash(directoryURL: URL) {
        guard let snapshot = currentSnapshot else { return }
        Task {
            let canApply = await model.canApplyStashCleanly(snapshot: snapshot)
            guard canApply else {
                showStashConflictAlert = true
                return
            }
            await model.applyLatestStash(snapshot: snapshot)
            await refresh(directoryURL: directoryURL)
        }
    }

    func undoLastCommit(directoryURL: URL) {
        guard let snapshot = currentSnapshot else { return }
        Task {
            await model.undoLastCommit(snapshot: snapshot)
            await refresh(directoryURL: directoryURL)
        }
    }

    func renameLastCommit(directoryURL: URL) {
        guard let snapshot = currentSnapshot else { return }
        let message = renameCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        Task {
            await model.amendCommitMessage(message, snapshot: snapshot)
            renameCommitMessage = ""
            await refresh(directoryURL: directoryURL)
        }
    }

    func syncWithBranch(_ branch: String, directoryURL: URL) {
        guard let snapshot = currentSnapshot else { return }
        Task {
            await model.syncWithBranch(branch, snapshot: snapshot)
            await refresh(directoryURL: directoryURL)
        }
    }

    func pullPreservingChanges(directoryURL: URL) {
        guard let snapshot = currentSnapshot else { return }
        Task {
            let result = await model.pullPreservingChanges(snapshot: snapshot)
            if result == .wouldConflict {
                showPullConflictAlert = true
            }
            await refresh(directoryURL: directoryURL)
        }
    }

    func syncWithRemote(directoryURL: URL) {
        guard let snapshot = currentSnapshot else { return }
        Task {
            await model.syncWithRemote(snapshot: snapshot)
            await refresh(directoryURL: directoryURL)
        }
    }

    func pushSetUpstream(directoryURL: URL) {
        guard let snapshot = currentSnapshot,
              let branch = snapshot.branchName else { return }
        Task {
            await model.pushSetUpstream(branch: branch, snapshot: snapshot)
            await refresh(directoryURL: directoryURL)
        }
    }

    func fetch(directoryURL: URL) {
        guard let snapshot = currentSnapshot else { return }
        Task {
            await model.fetch(snapshot: snapshot)
            await refresh(directoryURL: directoryURL)
        }
    }

    func createBranch(named name: String, directoryURL: URL) {
        guard let snapshot = currentSnapshot else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await model.createBranch(named: trimmed, snapshot: snapshot)
            await refresh(directoryURL: directoryURL)
        }
    }

    func performDiscard(_ target: GitInspectorDiscardTarget, directoryURL: URL) {
        Task {
            switch target {
            case .files(let files, let snapshot):
                await model.discardChanges(files: files, snapshot: snapshot)
            case .all(let snapshot):
                await model.discardAllChanges(snapshot: snapshot)
            }
            await refresh(directoryURL: directoryURL)
        }
    }

    var currentSnapshot: GitRepositoryStatusSnapshot? {
        model.snapshots.first { $0.repositoryRootURL == selectedRepoURL }
            ?? model.snapshots.first
    }
}
