import AtriumProtocol
import Foundation
import Observation

/// Runs the inspector's Git operations on the project's host and reports
/// how they went. Status itself arrives from the host as it changes; an
/// operation's effect is in it by the time the operation returns.
@MainActor
@Observable
final class GitInspectorModel {
    unowned let project: Project
    private(set) var activeTaskCount = 0
    var errorMessage: String?
    var successMessage: String?

    init(project: Project) {
        self.project = project
    }

    var snapshots: [GitRepositoryStatus] { project.repositories ?? [] }
    var hasCompletedInitialScan: Bool { project.repositories != nil }
    var isBusy: Bool { activeTaskCount > 0 }

    func stage(files: [GitChangedFile], snapshot: GitRepositoryStatus) async {
        await perform(.stage(paths: files.map(\.repositoryRelativePath)), in: snapshot)
    }

    func unstage(files: [GitChangedFile], snapshot: GitRepositoryStatus) async {
        await perform(.unstage(paths: files.map(\.repositoryRelativePath)), in: snapshot)
    }

    func stageAll(snapshot: GitRepositoryStatus) async {
        await perform(.stage(paths: snapshot.unstagedFiles.map(\.repositoryRelativePath)), in: snapshot)
    }

    func unstageAll(snapshot: GitRepositoryStatus) async {
        await perform(.unstage(paths: snapshot.stagedFiles.map(\.repositoryRelativePath)), in: snapshot)
    }

    func discardChanges(files: [GitChangedFile], snapshot: GitRepositoryStatus) async {
        await perform(.discard(
            tracked: files.filter { $0.kind != .untracked }.map(\.repositoryRelativePath),
            untracked: files.filter { $0.kind == .untracked }.map(\.repositoryRelativePath)
        ), in: snapshot)
    }

    func discardAllChanges(snapshot: GitRepositoryStatus) async {
        await perform(.discardAll, in: snapshot)
    }

    func commit(message: String, snapshot: GitRepositoryStatus) async {
        await perform(.commit(message: message), in: snapshot, success: "Committed successfully")
    }

    /// Pushes, publishing the branch when it has no upstream yet.
    func push(snapshot: GitRepositoryStatus) async {
        await perform(.push(branch: snapshot.branchName), in: snapshot, success: "Pushed successfully")
    }

    func remoteURL(snapshot: GitRepositoryStatus) async -> String? {
        guard case .text(let url) = await run(.remoteURL, in: snapshot) else { return nil }
        return url
    }

    func pull(snapshot: GitRepositoryStatus) async {
        await perform(.pull, in: snapshot, success: "Pulled successfully")
    }

    func pullPreservingChanges(snapshot: GitRepositoryStatus) async -> PullPreservingResult? {
        guard case .pull(let result) = await run(.pullPreservingChanges, in: snapshot) else { return nil }
        if result == .clean { successMessage = "Pulled with local changes preserved" }
        return result
    }

    func syncWithBranch(_ branch: String, snapshot: GitRepositoryStatus) async {
        await perform(.rebase(onto: branch), in: snapshot, success: "Rebased onto \(branch)")
    }

    func syncWithRemote(snapshot: GitRepositoryStatus) async {
        await perform(.pullRebase, in: snapshot, success: "Synced with remote")
    }

    func fetch(snapshot: GitRepositoryStatus) async {
        await perform(.fetch, in: snapshot.mainRepositoryURL)
    }

    /// Throttled and silent, for automatic refreshes. An explicit refresh uses `fetch`.
    func fetchIfStale(snapshot: GitRepositoryStatus) async {
        _ = try? await project.git(.fetchIfStale, in: snapshot.mainRepositoryURL)
    }

    func commitLog(snapshot: GitRepositoryStatus, limit: Int = 200) async -> [GitLogEntry] {
        guard case .log(let entries) = await run(.log(limit: limit), in: snapshot) else { return [] }
        return entries
    }

    func switchBranch(to branch: String, at repository: URL) async {
        await perform(.switchBranch(branch), in: repository, success: "Switched to \(branch)")
    }

    func createBranch(named name: String, snapshot: GitRepositoryStatus) async {
        await perform(.createBranch(name), in: snapshot, success: "Created branch \(name)")
    }

    func stashAndSwitch(to branch: String, at repository: URL) async {
        guard await perform(.stash(message: nil), in: repository) else { return }
        await perform(.switchBranch(branch), in: repository)
    }

    func stashAll(message: String, snapshot: GitRepositoryStatus) async {
        await perform(.stash(message: message), in: snapshot, success: "Changes stashed")
    }

    func undoLastCommit(snapshot: GitRepositoryStatus) async {
        await perform(.undoLastCommit, in: snapshot, success: "Last commit undone")
    }

    func amendCommitMessage(_ message: String, snapshot: GitRepositoryStatus) async {
        await perform(.amendMessage(message), in: snapshot, success: "Commit renamed")
    }

    func canApplyStashCleanly(snapshot: GitRepositoryStatus) async -> Bool {
        guard case .flag(let canApply) = await run(.canApplyStash, in: snapshot) else { return false }
        return canApply
    }

    func applyLatestStash(snapshot: GitRepositoryStatus) async {
        await perform(.popStash, in: snapshot, success: "Stash applied")
    }

    func stashList(snapshot: GitRepositoryStatus) async -> [GitStashEntry] {
        guard case .stashes(let stashes) = await run(.stashes, in: snapshot) else { return [] }
        return stashes
    }

    func dropStash(index: Int, snapshot: GitRepositoryStatus) async {
        await perform(.dropStash(index: index), in: snapshot, success: "Stash dropped")
    }

    func applyStash(index: Int, snapshot: GitRepositoryStatus) async {
        await perform(.applyStash(index: index), in: snapshot, success: "Stash applied")
    }

    func initializeRepository() async {
        await perform(.initialize, in: project.root, success: "Repository initialized")
    }

    func hasUncommittedChanges(at repository: URL) async -> Bool {
        guard case .flag(let isDirty) = await run(.hasUncommittedChanges, in: repository) else { return false }
        return isDirty
    }

    /// Shares the inspector's busy indicator without sharing an operation's error state.
    func withBusyState(_ operation: () async throws -> Void) async rethrows {
        activeTaskCount += 1
        defer { activeTaskCount -= 1 }
        try await operation()
    }

    // MARK: - Private

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

    private func run(_ operation: GitOperation, in snapshot: GitRepositoryStatus) async -> GitReply? {
        await run(operation, in: snapshot.repositoryRootURL)
    }

    /// Never clears `errorMessage`: yanking an error alert away mid-presentation
    /// crashes AppKit's sheet animation. The alert clears it when dismissed.
    private func run(_ operation: GitOperation, in repository: URL) async -> GitReply? {
        activeTaskCount += 1
        defer { activeTaskCount -= 1 }
        do {
            return try await project.git(operation, in: repository)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
