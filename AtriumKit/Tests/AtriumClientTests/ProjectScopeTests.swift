@testable import AtriumClient
import AtriumProtocol
import Foundation
import Testing

struct ProjectScopeTests {
    @Test func folderOfRepositoriesShowsThePickedOneThroughItsWorktree() async throws {
        let (host, connection, workspaceID) = try await connectedHost(projectPath: "/p")
        let scope = host.scope(for: workspaceID)
        #expect(scope === host.scope(for: workspaceID))
        connection.onEvent?(.git(scope.gitScope, repositories: [repository("/p/A"), repository("/p/B")]))
        #expect(scope.nestedRepositories.map(\.name) == ["A", "B"])
        #expect(scope.filesRoot.filePath == "/p")
        #expect(scope.title == nil)

        scope.showWorktree(URL(filePath: "/wt/A-x"), of: URL(filePath: "/p/A"))
        connection.onEvent?(.git(scope.gitScope, repositories: [
            repository("/p/A", worktree: "/wt/A-x", branch: "feature-x"), repository("/p/B"),
        ]))
        #expect(scope.filesRoot.filePath == "/wt/A-x")
        #expect(scope.title == "A · feature-x")
        #expect(scope.status?.name == "A")
        // Commands stay in the project folder, which no worktree holds.
        #expect(scope.root.filePath == "/p")

        scope.include(URL(filePath: "/p/B/file.swift"))
        #expect(scope.filesRoot.filePath == "/p/B")
        scope.include(URL(filePath: "/p/README.md"))
        #expect(scope.selectedRepository == nil)
        #expect(scope.filesRoot.filePath == "/p")
        host.stop()
    }

    @Test func projectInsideARepositoryFollowsItsWorktreeUntilItsGone() async throws {
        let (host, connection, workspaceID) = try await connectedHost(projectPath: "/r/app")
        let scope = host.scope(for: workspaceID)
        scope.show(TaskCheckout(repository: URL(filePath: "/r"), worktree: URL(filePath: "/wt")))
        // Before the status arrives, the chosen worktree is trusted.
        #expect(scope.root.filePath == "/wt/app")
        #expect(scope.filesRoot == scope.root)

        connection.onEvent?(.git(scope.gitScope, repositories: [repository("/r", worktree: "/wt", branch: "fix")]))
        #expect(scope.title == "fix")
        #expect(scope.nestedRepositories.isEmpty)

        // The worktree was removed, so the host shows the main checkout.
        connection.onEvent?(.git(scope.gitScope, repositories: [repository("/r", branch: "main")]))
        #expect(scope.root.filePath == "/r/app")
        #expect(scope.title == "main")
        host.stop()
    }

    private func connectedHost(projectPath: String) async throws -> (HostClient, FakeConnection, UUID) {
        let connection = FakeConnection()
        let host = HostClient(localID: "local", name: "Mac") { connection }
        host.start()
        for _ in 0..<200 where !host.isConnected {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(host.isConnected)
        let workspaceID = UUID()
        let workspace = WireWorkspace(
            id: workspaceID, name: "Project", path: projectPath, directory: projectPath,
            projectType: "", scratchpad: "", hasRunningCommand: false
        )
        connection.onEvent?(.tasks(WireTasksSnapshot(tasks: [], workspaces: [workspace], providers: [])))
        return (host, connection, workspaceID)
    }

    /// A repository's status, seen through `worktree` when one is given.
    private func repository(_ main: String, worktree: String? = nil, branch: String = "main") -> GitRepositoryStatus {
        var worktrees = [GitWorktreeInfo(path: URL(filePath: main), branch: "main", isMain: true, isCurrent: worktree == nil)]
        if let worktree {
            worktrees.append(GitWorktreeInfo(path: URL(filePath: worktree), branch: branch, isCurrent: true))
        }
        return GitRepositoryStatus(
            repositoryRootURL: URL(filePath: worktree ?? main), branchName: branch, localBranches: [],
            worktrees: worktrees, stagedFiles: [], unstagedFiles: [], unpushedCommits: [],
            remoteAheadCount: 0, hasTrackingBranch: false
        )
    }
}
