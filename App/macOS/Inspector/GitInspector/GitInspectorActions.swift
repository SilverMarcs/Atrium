import AtriumClient
import AtriumProtocol
import Foundation
import Observation

/// The Git inspector of one project: its source control, and the inspector's
/// own alerts and sheets in flight, with the actions behind them.
@MainActor
@Observable
final class GitInspectorState {
    unowned let project: Project
    let model: SourceControl
    var selectedFileID: String?
    var commitMessage = ""
    var showNewBranchSheet = false
    var newBranchName = ""
    var showStashAlert = false
    var stashMessage = ""
    var unpushedExpanded = true
    var stagedExpanded = true
    var unstagedExpanded = true
    var showStashConflictAlert = false
    var showRenameCommitAlert = false
    var renameCommitMessage = ""
    var showUndoLastCommitAlert = false
    var showSyncWithBranchSheet = false
    var showCommitLogSheet = false
    /// The repository the branch sheet manages while it's shown. Kept as it
    /// was opened, so the sheet stays put while the status reloads under it.
    var branchListSnapshot: GitRepositoryStatus?
    var showStashListSheet = false

    init(project: Project) {
        self.project = project
        model = SourceControl(host: project.host, workspaceID: project.workspaceID)
    }

    var currentSnapshot: GitRepositoryStatus? { model.status }

    /// Handles state-only actions. View-specific actions (`.commit`, `.showInFileTree`)
    /// are no-ops here and must be dispatched by the calling view.
    func perform(_ action: GitAction) {
        switch action {
        case .stage(let files, let snapshot):
            Task { await model.stage(files, in: snapshot) }
        case .unstage(let files, let snapshot):
            Task { await model.unstage(files, in: snapshot) }
        case .stageAll(let snapshot):
            Task { await model.stage(snapshot.unstagedFiles, in: snapshot) }
        case .unstageAll(let snapshot):
            Task { await model.unstage(snapshot.stagedFiles, in: snapshot) }
        case .discard(let files, let snapshot):
            model.prompt = .discard(files, snapshot)
        case .discardAll(let snapshot):
            model.prompt = .discard(nil, snapshot)
        case .push(let snapshot):
            Task { await model.push(snapshot) }
        case .commit, .showInFileTree:
            break
        }
    }

    /// Points a repository at one of its worktrees (or back at the main one).
    /// Changing the project's checkouts follows a new Git scope, so no refresh.
    func activateWorktree(_ worktree: GitWorktreeInfo, in snapshot: GitRepositoryStatus) {
        project.scope.showWorktree(worktree.isMain ? nil : worktree.path, of: snapshot.mainRepositoryURL)
    }

    /// Reconciles inspector navigation after the branch manager changes a checkout.
    func finishBranchOperation(mainRepositoryURL: URL, didConvert: Bool) {
        guard didConvert else { return }
        project.scope.showWorktree(nil, of: mainRepositoryURL)
    }

    func confirmStashAll() {
        guard let snapshot = currentSnapshot else { return }
        let message = stashMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        Task {
            await model.stashAll(message: message, in: snapshot)
            stashMessage = ""
        }
    }

    func applyLatestStash() {
        guard let snapshot = currentSnapshot else { return }
        Task {
            guard await model.canApplyStashCleanly(snapshot) else {
                showStashConflictAlert = true
                return
            }
            await model.applyLatestStash(snapshot)
        }
    }

    func undoLastCommit() {
        guard let snapshot = currentSnapshot else { return }
        Task { await model.undoLastCommit(snapshot) }
    }

    func renameLastCommit() {
        guard let snapshot = currentSnapshot else { return }
        let message = renameCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        Task {
            await model.amendCommitMessage(message, in: snapshot)
            renameCommitMessage = ""
        }
    }

    func syncWithBranch(_ branch: String) {
        guard let snapshot = currentSnapshot else { return }
        Task { await model.rebase(snapshot, onto: branch) }
    }

    func syncWithRemote() {
        guard let snapshot = currentSnapshot else { return }
        Task { await model.syncWithRemote(snapshot) }
    }

    func fetch() {
        guard let snapshot = currentSnapshot else { return }
        Task { await model.fetch(snapshot) }
    }

    func createBranch(named name: String) {
        guard let snapshot = currentSnapshot else { return }
        Task { await model.createBranch(named: name, in: snapshot) }
    }
}
