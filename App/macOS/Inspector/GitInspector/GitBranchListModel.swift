import Foundation
import Observation

/// Owns the branch sheet's state and its delete → inspector refresh → reload sequence.
@MainActor
@Observable
final class GitBranchListModel {
    private(set) var listing = GitBranchListing()
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var actionError: String?
    private(set) var pendingAction: GitBranchAction?
    /// The failed delete that the error alert offers to retry with force.
    private(set) var forceableAction: GitBranchAction?
    private var isPerforming = false
    private var loadRevision = 0
    let repositoryRootURL: URL
    private let inspector: GitInspectorState

    var isBusy: Bool { isLoading || isPerforming || inspector.model.isBusy }
    var isConfirming: Bool {
        get { pendingAction != nil }
        set { if !newValue { pendingAction = nil } }
    }
    var isShowingActionError: Bool {
        get { actionError != nil }
        set {
            if !newValue {
                actionError = nil
                forceableAction = nil
            }
        }
    }

    init(snapshot: GitRepositoryStatus, inspector: GitInspectorState) {
        repositoryRootURL = snapshot.repositoryRootURL
        self.inspector = inspector
    }

    private func git(_ operation: GitOperation) async throws -> GitReply {
        try await inspector.project.git(operation, in: repositoryRootURL)
    }

    func load() async {
        loadRevision += 1
        let revision = loadRevision
        isLoading = listing.branches.isEmpty && listing.linkedWorktrees.isEmpty
        loadError = nil
        defer { if revision == loadRevision { isLoading = false } }
        do {
            guard case .branches(let loaded) = try await git(.branches) else { throw HostClientError.unexpectedReply }
            try Task.checkCancellation()
            guard revision == loadRevision else { return }
            listing = loaded
        } catch is CancellationError {
        } catch {
            if revision == loadRevision { loadError = error.localizedDescription }
        }
    }

    func unavailableReason(for action: GitBranchAction) -> String? {
        switch action {
        case .deleteBranch(let branch): listing.deletionUnavailableReason(for: branch)
        case .deleteWorktree(let worktree): worktree.deletionUnavailableReason
        }
    }

    func request(_ action: GitBranchAction) async {
        guard !isBusy, unavailableReason(for: action) == nil else { return }
        if case .deleteBranch(let branch) = action, branch.isMergedIntoCurrentBranch {
            await confirm(action)
        } else {
            pendingAction = action
        }
    }

    func confirm(_ action: GitBranchAction) async {
        await run(action, force: false)
    }

    /// Retries a delete that Git refused, discarding what made it refuse.
    func forceDelete(_ action: GitBranchAction) async {
        await run(action, force: true)
    }

    private func run(_ action: GitBranchAction, force: Bool) async {
        guard !isBusy, unavailableReason(for: action) == nil else { return }
        pendingAction = nil
        forceableAction = nil
        let retry = force ? nil : forceRetry(for: action)
        await perform(forceRetry: retry) {
            switch action {
            case .deleteBranch(let branch):
                _ = try await self.git(.deleteBranch(name: branch.name, force: force || !branch.isMergedIntoCurrentBranch))
                return "Deleted branch \(branch.name)"
            case .deleteWorktree(let worktree):
                _ = try await self.git(.deleteWorktree(worktree.path, force: force))
                return "Deleted worktree \(worktree.displayName)"
            }
        }
    }

    /// The delete to offer again with force if this attempt fails, when
    /// forcing would change what Git does.
    private func forceRetry(for action: GitBranchAction) -> GitBranchAction? {
        switch action {
        case .deleteBranch(let branch): branch.isMergedIntoCurrentBranch ? action : nil
        case .deleteWorktree: action
        }
    }

    private func perform(forceRetry: GitBranchAction?, _ operation: () async throws -> String) async {
        isPerforming = true
        actionError = nil
        inspector.model.successMessage = nil
        defer { isPerforming = false }
        await inspector.model.withBusyState {
            do {
                self.inspector.model.successMessage = try await operation()
            } catch {
                self.actionError = error.localizedDescription
                self.forceableAction = forceRetry
            }
            await self.load()
        }
    }
}
