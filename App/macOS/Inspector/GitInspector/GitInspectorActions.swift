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
    var unpushedExpanded = true
    var stagedExpanded = true
    var unstagedExpanded = true
    var showRenameCommitAlert = false
    var renameCommitMessage = ""
    var showUndoLastCommitAlert = false
    var showCommitLogSheet = false
    /// The repository the branch sheet manages while it's shown. Kept as it
    /// was opened, so the sheet stays put while the status reloads under it.
    var branchListSnapshot: GitRepositoryStatus?

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

    func fetch() {
        guard let snapshot = currentSnapshot else { return }
        Task { await model.fetch(snapshot) }
    }

    func createBranch(named name: String) {
        guard let snapshot = currentSnapshot else { return }
        Task { await model.createBranch(named: name, in: snapshot) }
    }
}
