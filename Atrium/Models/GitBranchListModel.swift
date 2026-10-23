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
    private let directoryURL: URL
    private let inspector: GitInspectorState
    private let repository = GitRepository.shared

    var isBusy: Bool { isLoading || isPerforming || inspector.model.isBusy }
    var isConfirming: Bool {
        get { pendingAction != nil }
        set { if !newValue { pendingAction = nil } }
    }
    var isShowingActionError: Bool {
        get { actionError != nil }
        set { if !newValue { actionError = nil } }
    }

    init(snapshot: GitRepositoryStatusSnapshot, directoryURL: URL, inspector: GitInspectorState) {
        repositoryRootURL = snapshot.repositoryRootURL
        mainRepositoryURL = snapshot.mainRepositoryURL
        self.directoryURL = directoryURL
        self.inspector = inspector
    }

    func load() async {
        loadRevision += 1
        let revision = loadRevision
        isLoading = listing.branches.isEmpty && listing.linkedWorktrees.isEmpty
        loadError = nil
        defer { if revision == loadRevision { isLoading = false } }
        do {
            let loaded = try await repository.allBranchesDetailed(at: repositoryRootURL)
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
                try await self.repository.deleteBranch(branch.name, force: !branch.isMergedIntoCurrentBranch, at: self.repositoryRootURL)
                return "Deleted branch \(branch.name)"
            case .deleteWorktree(let worktree):
                try await self.repository.deleteWorktree(at: worktree.path, in: self.repositoryRootURL)
                return "Deleted worktree \(worktree.displayName)"
            case .convertWorktree(let worktree):
                try await self.repository.convertWorktreeToBranch(at: worktree.path, in: self.repositoryRootURL)
                self.repositoryRootURL = self.mainRepositoryURL
                return "Converted worktree to branch \(worktree.branch ?? worktree.displayName)"
            }
        }
    }

    func sync(_ branch: GitBranchInfo) async {
        guard !isBusy, let upstream = branch.upstream else { return }
        await perform {
            let result = try await self.repository.syncBranchWithUpstream(
                localBranch: branch.name, upstreamBranch: upstream, at: self.repositoryRootURL
            )
            return result == .alreadyUpToDate ? "'\(branch.name)' is already up to date with upstream."
                : "Synced '\(branch.name)' with upstream successfully."
        }
    }

    func merge(_ source: GitBranchInfo, into target: GitBranchInfo) async {
        guard !isBusy, !target.isRemote, source.id != target.id else { return }
        await perform {
            try await self.repository.mergeBranch(source, into: target, at: self.mainRepositoryURL)
            return "Merged \(source.name) into \(target.name)"
        }
    }

    func comparison(for branch: GitBranchInfo) -> GitCommitDiffSheetItem? {
        guard !branch.isCurrent, let head = listing.currentBranchName else { return nil }
        return GitCommitDiffSheetItem(range: GitBranchRange(base: branch.name, head: head),
                                      message: "Committed changes only", repositoryRootURL: repositoryRootURL)
    }

    private func perform(returningToMain: Bool = false, _ operation: () async throws -> String) async {
        isPerforming = true
        actionError = nil
        inspector.model.successMessage = nil
        let previousRoot = repositoryRootURL
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
            await self.inspector.finishBranchOperation(
                mainRepositoryURL: self.mainRepositoryURL, previousRoot: previousRoot,
                directoryURL: self.directoryURL, didConvert: didConvert
            )
        }
    }
}
