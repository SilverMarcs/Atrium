import AtriumClient
import AtriumProtocol
import Foundation
import Observation

/// Source control for one project on its host: the repository its scope
/// shows, the Git operations run there, and what they report or need
/// confirmed. Status itself arrives from the host as it changes; an
/// operation's effect is in it by the time the operation returns.
@MainActor
@Observable
final class SourceControl {
    let host: HostClient
    let workspaceID: UUID
    let scope: ProjectScope
    private var activeTaskCount = 0
    /// Never cleared by an operation: yanking an error alert away
    /// mid-presentation crashes AppKit's sheet animation. The alert clears it
    /// when dismissed.
    var errorMessage: String?
    var successMessage: String?
    /// The confirmation an operation is waiting on.
    var prompt: SourceControlPrompt?

    init(host: HostClient, workspaceID: UUID) {
        self.host = host
        self.workspaceID = workspaceID
        scope = host.scope(for: workspaceID)
    }

    var workspace: WorkspaceRef { WorkspaceRef(hostID: host.id, workspaceID: workspaceID) }
    /// Nil until the host has sent the project's status.
    var repositories: [GitRepositoryStatus]? { scope.repositories }
    /// The checkout shown.
    var status: GitRepositoryStatus? { scope.status }
    var isBusy: Bool { activeTaskCount > 0 }

    // MARK: - Changes

    func stage(_ files: [GitChangedFile], in snapshot: GitRepositoryStatus) async {
        await perform(.stage(paths: files.map(\.repositoryRelativePath)), in: snapshot)
    }

    func unstage(_ files: [GitChangedFile], in snapshot: GitRepositoryStatus) async {
        await perform(.unstage(paths: files.map(\.repositoryRelativePath)), in: snapshot)
    }

    /// Commits the staged changes; a blank message commits nothing.
    /// Whether it committed.
    @discardableResult
    func commit(message: String, in snapshot: GitRepositoryStatus) async -> Bool {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !snapshot.stagedFiles.isEmpty else { return false }
        return await perform(.commit(message: message), in: snapshot, success: "Committed successfully")
    }

    func initializeRepository() async {
        await perform(.initialize, in: scope.root, success: "Repository initialized")
    }

    // MARK: - Remote

    func fetch(_ snapshot: GitRepositoryStatus) async {
        await perform(.fetch, in: snapshot.mainRepositoryURL)
    }

    /// Throttled and silent, for automatic refreshes. An explicit refresh uses `fetch`.
    func fetchIfStale(_ snapshot: GitRepositoryStatus) async {
        _ = try? await host.git(.fetchIfStale, in: snapshot.mainRepositoryURL, workspace: workspaceID)
    }

    /// Fetches, then pushes: asking first to publish a branch the remote
    /// doesn't have, or to rebase when the remote has moved on too.
    func push(_ snapshot: GitRepositoryStatus) async {
        guard let snapshot = await fetched(snapshot) else { return }
        if !snapshot.hasTrackingBranch {
            prompt = .publish(snapshot)
        } else if snapshot.remoteAheadCount > 0 {
            prompt = .diverged(snapshot)
        } else if !snapshot.unpushedCommits.isEmpty {
            await publish(snapshot)
        }
    }

    /// Fetches, then pulls: asking first to rebase when there are local
    /// commits too, and keeping uncommitted changes when they don't conflict.
    func pull(_ snapshot: GitRepositoryStatus) async {
        guard let snapshot = await fetched(snapshot) else { return }
        if !snapshot.unpushedCommits.isEmpty {
            prompt = .diverged(snapshot)
        } else if snapshot.isDirty {
            guard case .pull(let result) = await run(.pullPreservingChanges, in: snapshot.repositoryRootURL) else { return }
            if result == .wouldConflict { prompt = .pullConflict }
            else { successMessage = "Pulled with local changes preserved" }
        } else {
            await perform(.pull, in: snapshot, success: "Pulled successfully")
        }
    }

    func syncWithRemote(_ snapshot: GitRepositoryStatus) async {
        await perform(.pullRebase, in: snapshot, success: "Synced with remote")
    }

    func rebase(_ snapshot: GitRepositoryStatus, onto branch: String) async {
        await perform(.rebase(onto: branch), in: snapshot, success: "Rebased onto \(branch)")
    }

    func remoteURL(_ snapshot: GitRepositoryStatus) async -> String? {
        guard case .text(let url) = await run(.remoteURL, in: snapshot.repositoryRootURL) else { return nil }
        return url
    }

    func commitLog(_ snapshot: GitRepositoryStatus, limit: Int = 200) async -> [GitLogEntry] {
        guard case .log(let entries) = await run(.log(limit: limit), in: snapshot.repositoryRootURL) else { return [] }
        return entries
    }

    // MARK: - Branches

    /// Shows a branch: in the worktree that has it checked out, or else
    /// switched to in the main worktree, offering to stash its changes first.
    /// Plain branches live in the main worktree, so a linked worktree in view
    /// is left untouched.
    func selectBranch(_ branch: String, in snapshot: GitRepositoryStatus) async {
        guard !branch.isEmpty, branch != snapshot.branchName else { return }
        let main = snapshot.mainRepositoryURL
        if let worktree = snapshot.worktrees.first(where: { $0.branch == branch && !$0.isBare }) {
            scope.showWorktree(worktree.isMain ? nil : worktree.path, of: main)
            return
        }
        let isOtherWorktree = main != snapshot.repositoryRootURL
        let isDirty = isOtherWorktree ? await hasUncommittedChanges(at: main) : snapshot.isDirty
        if isDirty {
            prompt = .stashAndSwitch(branch: branch, repository: main, isOtherWorktree: isOtherWorktree)
        } else {
            await switchBranch(to: branch, at: main)
        }
    }

    func createBranch(named name: String, in snapshot: GitRepositoryStatus) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await perform(.createBranch(name), in: snapshot, success: "Created branch \(name)")
    }

    // MARK: - Commits and stashes

    func undoLastCommit(_ snapshot: GitRepositoryStatus) async {
        await perform(.undoLastCommit, in: snapshot, success: "Last commit undone")
    }

    func amendCommitMessage(_ message: String, in snapshot: GitRepositoryStatus) async {
        await perform(.amendMessage(message), in: snapshot, success: "Commit renamed")
    }

    func stashAll(message: String, in snapshot: GitRepositoryStatus) async {
        await perform(.stash(message: message), in: snapshot, success: "Changes stashed")
    }

    func canApplyStashCleanly(_ snapshot: GitRepositoryStatus) async -> Bool {
        guard case .flag(let canApply) = await run(.canApplyStash, in: snapshot.repositoryRootURL) else { return false }
        return canApply
    }

    func applyLatestStash(_ snapshot: GitRepositoryStatus) async {
        await perform(.popStash, in: snapshot, success: "Stash applied")
    }

    func stashList(_ snapshot: GitRepositoryStatus) async -> [GitStashEntry] {
        guard case .stashes(let stashes) = await run(.stashes, in: snapshot.repositoryRootURL) else { return [] }
        return stashes
    }

    func applyStash(index: Int, in snapshot: GitRepositoryStatus) async {
        await perform(.applyStash(index: index), in: snapshot, success: "Stash applied")
    }

    func dropStash(index: Int, in snapshot: GitRepositoryStatus) async {
        await perform(.dropStash(index: index), in: snapshot, success: "Stash dropped")
    }

    // MARK: - Prompts

    /// Goes ahead with what the prompt asked about.
    func confirm(_ prompt: SourceControlPrompt) async {
        switch prompt {
        case .discard(let files, let snapshot):
            guard let files else {
                await perform(.discardAll, in: snapshot)
                return
            }
            await perform(.discard(
                tracked: files.filter { $0.kind != .untracked }.map(\.repositoryRelativePath),
                untracked: files.filter { $0.kind == .untracked }.map(\.repositoryRelativePath)
            ), in: snapshot)
        case .stashAndSwitch(let branch, let repository, _):
            guard await perform(.stash(message: nil), in: repository) else { return }
            await switchBranch(to: branch, at: repository)
        case .publish(let snapshot):
            await publish(snapshot)
        case .diverged(let snapshot):
            await syncWithRemote(snapshot)
        case .pullConflict:
            break
        }
    }

    // MARK: - Running operations

    /// Runs an operation without reporting its failure, for callers with
    /// their own error handling.
    func git(_ operation: GitOperation, in repository: URL) async throws -> GitReply {
        try await host.git(operation, in: repository, workspace: workspaceID)
    }

    /// Shares the busy indicator without sharing an operation's error state.
    func withBusyState(_ operation: () async throws -> Void) async rethrows {
        activeTaskCount += 1
        defer { activeTaskCount -= 1 }
        try await operation()
    }

    /// Pushes, publishing the branch when it has no upstream yet.
    private func publish(_ snapshot: GitRepositoryStatus) async {
        await perform(.push(branch: snapshot.branchName), in: snapshot, success: "Pushed successfully")
    }

    private func switchBranch(to branch: String, at repository: URL) async {
        guard await perform(.switchBranch(branch), in: repository, success: "Switched to \(branch)") else { return }
        scope.showWorktree(nil, of: repository)
    }

    private func hasUncommittedChanges(at repository: URL) async -> Bool {
        guard case .flag(let isDirty) = await run(.hasUncommittedChanges, in: repository) else { return false }
        return isDirty
    }

    /// The status once a fetch has brought in what's on the remote.
    private func fetched(_ snapshot: GitRepositoryStatus) async -> GitRepositoryStatus? {
        guard await perform(.fetch, in: snapshot.mainRepositoryURL) else { return nil }
        return status
    }

    @discardableResult
    private func perform(_ operation: GitOperation, in snapshot: GitRepositoryStatus, success: String? = nil) async -> Bool {
        await perform(operation, in: snapshot.repositoryRootURL, success: success)
    }

    @discardableResult
    private func perform(_ operation: GitOperation, in repository: URL, success: String? = nil) async -> Bool {
        successMessage = nil
        guard await run(operation, in: repository) != nil else { return false }
        if let success { successMessage = success }
        return true
    }

    private func run(_ operation: GitOperation, in repository: URL) async -> GitReply? {
        activeTaskCount += 1
        defer { activeTaskCount -= 1 }
        do {
            return try await git(operation, in: repository)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
