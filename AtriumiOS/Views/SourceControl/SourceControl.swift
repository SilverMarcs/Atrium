import Foundation
import Observation

/// Source control for one project on its host: the repository shown, and
/// operations run in it. Status arrives from the host as it changes.
@MainActor
@Observable
final class SourceControl {
    let host: HostClient
    let workspaceID: UUID
    /// The main checkout of the repository shown, when the project has several.
    var selectedRepository: URL?

    init(host: HostClient, workspaceID: UUID) {
        self.host = host
        self.workspaceID = workspaceID
    }

    var scope: GitScope { GitScope(workspaceID: workspaceID) }
    var workspace: WorkspaceRef { WorkspaceRef(hostID: host.id, workspaceID: workspaceID) }
    /// Nil until the host has sent the project's status.
    var repositories: [GitRepositoryStatus]? { host.gitStatuses[scope] }
    var status: GitRepositoryStatus? {
        repositories?.first { $0.mainRepositoryURL == selectedRepository } ?? repositories?.first
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
