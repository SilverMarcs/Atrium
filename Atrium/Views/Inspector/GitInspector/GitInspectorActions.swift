import AtriumProtocol
import Foundation
import Observation

enum GitInspectorDiscardTarget {
    case files([GitChangedFile], GitRepositoryStatus)
    case all(GitRepositoryStatus)
}

struct PendingBranchSwitch {
    var branch: String
    var repositoryRootURL: URL
}

/// The Git inspector of one project: which repository it shows and the
/// alerts and sheets in flight, with the actions behind them.
@MainActor
@Observable
final class GitInspectorState {
    unowned let project: Project
    let model: GitInspectorModel
    var selectedRepoURL: URL?
    var selectedFileID: String?
    var commitMessage = ""
    var discardTarget: GitInspectorDiscardTarget?
    var pendingBranchSwitch: PendingBranchSwitch?
    var showNewBranchSheet = false
    var newBranchName = ""
    var showStashAlert = false
    var stashMessage = ""
    var unpushedExpanded = true
    var stagedExpanded = true
    var unstagedExpanded = true
    var showPushUpstreamAlert = false
    var showPullRebaseAlert = false
    var showPullConflictAlert = false
    var showStashConflictAlert = false
    var showRenameCommitAlert = false
    var renameCommitMessage = ""
    var showUndoLastCommitAlert = false
    var showSyncWithBranchSheet = false
    var showCommitLogSheet = false
    var showBranchListSheet = false
    var showStashListSheet = false

    init(project: Project) {
        self.project = project
        model = GitInspectorModel(project: project)
    }

    var currentSnapshot: GitRepositoryStatus? {
        model.snapshots.first { $0.mainRepositoryURL == selectedRepoURL } ?? model.snapshots.first
    }

    /// Handles state-only actions. View-specific actions (`.commit`, `.showInFileTree`)
    /// are no-ops here and must be dispatched by the calling view.
    func perform(_ action: GitAction) {
        switch action {
        case .stage(let files, let snapshot):
            Task { await model.stage(files: files, snapshot: snapshot) }
        case .unstage(let files, let snapshot):
            Task { await model.unstage(files: files, snapshot: snapshot) }
        case .stageAll(let snapshot):
            Task { await model.stageAll(snapshot: snapshot) }
        case .unstageAll(let snapshot):
            Task { await model.unstageAll(snapshot: snapshot) }
        case .discard(let files, let snapshot):
            discardTarget = .files(files, snapshot)
        case .discardAll(let snapshot):
            discardTarget = .all(snapshot)
        case .push(let snapshot):
            Task { await model.push(snapshot: snapshot) }
        case .commit, .showInFileTree:
            break
        }
    }

    /// Plain branches live in the repository's main worktree, so a branch switch
    /// always targets that root — a linked worktree in view is left untouched (it's
    /// isolated) and the dirty check runs against the main worktree, not it.
    func switchBranch(to branch: String, snapshot: GitRepositoryStatus) {
        let rootURL = snapshot.mainRepositoryURL
        Task {
            let isDirty = rootURL == snapshot.repositoryRootURL
                ? snapshot.isDirty
                : await model.hasUncommittedChanges(at: rootURL)
            if isDirty {
                pendingBranchSwitch = PendingBranchSwitch(branch: branch, repositoryRootURL: rootURL)
            } else {
                await model.switchBranch(to: branch, at: rootURL)
                project.worktrees[rootURL] = nil
            }
        }
    }

    func confirmStashAndSwitch() {
        guard let pending = pendingBranchSwitch else { return }
        Task {
            await model.stashAndSwitch(to: pending.branch, at: pending.repositoryRootURL)
            project.worktrees[pending.repositoryRootURL] = nil
        }
    }

    /// Points a repository at one of its worktrees (or back at the main one).
    /// Changing the project's checkouts follows a new Git scope, so no refresh.
    func activateWorktree(_ worktree: GitWorktreeInfo, in snapshot: GitRepositoryStatus) {
        let rootURL = snapshot.mainRepositoryURL
        project.worktrees[rootURL] = worktree.isMain ? nil : worktree.path.standardizedFileURL
        selectedRepoURL = rootURL
    }

    /// Reconciles inspector navigation after the branch manager changes a checkout.
    func finishBranchOperation(mainRepositoryURL: URL, didConvert: Bool) {
        guard didConvert else { return }
        project.worktrees[mainRepositoryURL] = nil
        selectedRepoURL = mainRepositoryURL
    }

    func confirmStashAll() {
        guard let snapshot = currentSnapshot else { return }
        let message = stashMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        Task {
            await model.stashAll(message: message, snapshot: snapshot)
            stashMessage = ""
        }
    }

    func applyLatestStash() {
        guard let snapshot = currentSnapshot else { return }
        Task {
            guard await model.canApplyStashCleanly(snapshot: snapshot) else {
                showStashConflictAlert = true
                return
            }
            await model.applyLatestStash(snapshot: snapshot)
        }
    }

    func undoLastCommit() {
        guard let snapshot = currentSnapshot else { return }
        Task { await model.undoLastCommit(snapshot: snapshot) }
    }

    func renameLastCommit() {
        guard let snapshot = currentSnapshot else { return }
        let message = renameCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        Task {
            await model.amendCommitMessage(message, snapshot: snapshot)
            renameCommitMessage = ""
        }
    }

    func syncWithBranch(_ branch: String) {
        guard let snapshot = currentSnapshot else { return }
        Task { await model.syncWithBranch(branch, snapshot: snapshot) }
    }

    func pullPreservingChanges() {
        guard let snapshot = currentSnapshot else { return }
        Task {
            if await model.pullPreservingChanges(snapshot: snapshot) == .wouldConflict {
                showPullConflictAlert = true
            }
        }
    }

    func syncWithRemote() {
        guard let snapshot = currentSnapshot else { return }
        Task { await model.syncWithRemote(snapshot: snapshot) }
    }

    func pushSetUpstream() {
        guard let snapshot = currentSnapshot else { return }
        Task { await model.push(snapshot: snapshot) }
    }

    func fetch() {
        guard let snapshot = currentSnapshot else { return }
        Task { await model.fetch(snapshot: snapshot) }
    }

    func createBranch(named name: String) {
        guard let snapshot = currentSnapshot else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await model.createBranch(named: trimmed, snapshot: snapshot) }
    }

    func performDiscard(_ target: GitInspectorDiscardTarget) {
        Task {
            switch target {
            case .files(let files, let snapshot):
                await model.discardChanges(files: files, snapshot: snapshot)
            case .all(let snapshot):
                await model.discardAllChanges(snapshot: snapshot)
            }
        }
    }
}
