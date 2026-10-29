import AtriumClient
import AtriumProtocol
import Foundation
import Observation

/// Owns the branch sheet's state and operation → inspector refresh → reload sequence.
@MainActor
@Observable
final class GitBranchListModel {
    private(set) var listing = GitBranchListing()
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var actionError: String?
    private(set) var pendingAction: GitBranchAction?
    private var isPerforming = false
    private var loadRevision = 0
    private var repositoryRootURL: URL
    private let mainRepositoryURL: URL
    private let inspector: GitInspectorState

    var isBusy: Bool { isLoading || isPerforming || inspector.model.isBusy }
    var isConfirming: Bool {
        get { pendingAction != nil }
        set { if !newValue { pendingAction = nil } }
    }
    var isShowingActionError: Bool {
        get { actionError != nil }
        set { if !newValue { actionError = nil } }
    }

    init(snapshot: GitRepositoryStatus, inspector: GitInspectorState) {
        repositoryRootURL = snapshot.repositoryRootURL
        mainRepositoryURL = snapshot.mainRepositoryURL
        self.inspector = inspector
    }

    private func git(_ operation: GitOperation, in repository: URL? = nil) async throws -> GitReply {
        try await inspector.project.git(operation, in: repository ?? repositoryRootURL)
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
        case .convertWorktree(let worktree):
            worktree.deletionUnavailableReason ?? (worktree.branch == nil ? "A detached worktree has no branch to convert." : nil)
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
        guard !isBusy, unavailableReason(for: action) == nil else { return }
        pendingAction = nil
        let isConversion = if case .convertWorktree = action { true } else { false }
        await perform(returningToMain: isConversion) {
            switch action {
            case .deleteBranch(let branch):
                _ = try await self.git(.deleteBranch(name: branch.name, force: !branch.isMergedIntoCurrentBranch))
                return "Deleted branch \(branch.name)"
            case .deleteWorktree(let worktree):
                _ = try await self.git(.deleteWorktree(worktree.path))
                return "Deleted worktree \(worktree.displayName)"
            case .convertWorktree(let worktree):
                _ = try await self.git(.convertWorktree(worktree.path))
                self.repositoryRootURL = self.mainRepositoryURL
                return "Converted worktree to branch \(worktree.branch ?? worktree.displayName)"
            }
        }
    }

    func sync(_ branch: GitBranchInfo) async {
        guard !isBusy, let upstream = branch.upstream else { return }
        await perform {
            guard case .sync(let result) = try await self.git(.syncBranch(local: branch.name, upstream: upstream)) else {
                throw HostClientError.unexpectedReply
            }
            return result == .alreadyUpToDate ? "'\(branch.name)' is already up to date with upstream."
                : "Synced '\(branch.name)' with upstream successfully."
        }
    }

    func merge(_ source: GitBranchInfo, into target: GitBranchInfo) async {
        guard !isBusy, !target.isRemote, source.id != target.id else { return }
        await perform {
            _ = try await self.git(.mergeBranch(source: source, target: target), in: self.mainRepositoryURL)
            return "Merged \(source.name) into \(target.name)"
        }
    }

    func comparison(for branch: GitBranchInfo) -> GitCommitDiffSheetItem? {
        guard !branch.isCurrent, let head = listing.currentBranchName else { return nil }
        return GitCommitDiffSheetItem(project: inspector.project.id, range: GitBranchRange(base: branch.name, head: head),
                                      message: "Committed changes only", repositoryRootURL: repositoryRootURL)
    }

    private func perform(returningToMain: Bool = false, _ operation: () async throws -> String) async {
        isPerforming = true
        actionError = nil
        inspector.model.successMessage = nil
        var didConvert = false
        defer { isPerforming = false }
        await inspector.model.withBusyState {
            do {
                self.inspector.model.successMessage = try await operation()
                didConvert = returningToMain
            } catch {
                self.actionError = error.localizedDescription
            }
            await self.load()
            self.inspector.finishBranchOperation(mainRepositoryURL: self.mainRepositoryURL, didConvert: didConvert)
        }
    }
}
