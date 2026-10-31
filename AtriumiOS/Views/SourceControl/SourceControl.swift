import AtriumClient
import AtriumProtocol
import Foundation
import Observation

/// Source control for one project on its host: the repository shown, and
/// operations run in it. Status arrives from the host as it changes; which
/// repository and checkout it shows is the project's scope, shared with its
/// other pages.
@MainActor
@Observable
final class SourceControl {
    let host: HostClient
    let workspaceID: UUID
    let scope: ProjectScope

    init(host: HostClient, workspaceID: UUID) {
        self.host = host
        self.workspaceID = workspaceID
        scope = host.scope(for: workspaceID)
    }

    var workspace: WorkspaceRef { WorkspaceRef(hostID: host.id, workspaceID: workspaceID) }
    /// Nil until the host has sent the project's status.
    var repositories: [GitRepositoryStatus]? { scope.repositories }
    var status: GitRepositoryStatus? { scope.status }

    /// An occupied branch is viewed in its existing checkout, never checked out twice.
    func selectBranch(_ branch: String, in snapshot: GitRepositoryStatus) {
        guard !branch.isEmpty, branch != snapshot.branchName else { return }
        let repository = snapshot.mainRepositoryURL
        if let worktree = snapshot.worktrees.first(where: { $0.branch == branch && !$0.isBare }) {
            scope.showWorktree(worktree.isMain ? nil : worktree.path, of: repository)
            return
        }
        Task {
            do {
                _ = try await host.git(.switchBranch(branch), in: repository, workspace: workspaceID)
                scope.showWorktree(nil, of: repository)
            } catch {
                host.actionError = error.localizedDescription
            }
        }
    }

    /// Runs an operation in the repository shown, reporting a failure as an alert.
    func send(_ operation: GitOperation) {
        guard let repository = status?.repositoryRootURL else { return }
        Task { await perform(operation, in: repository) }
    }

    func perform(_ operation: GitOperation, in repository: URL) async {
        do {
            _ = try await host.git(operation, in: repository, workspace: workspaceID)
        } catch {
            host.actionError = error.localizedDescription
        }
    }
}
