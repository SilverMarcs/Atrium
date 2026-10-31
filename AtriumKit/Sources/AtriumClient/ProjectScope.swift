import AtriumProtocol
import Foundation
import Observation

/// Which checkouts of a project this device shows, shared by every page of the
/// project: Source Control, Files, Search and Commands. A repository is seen
/// through its main checkout unless a linked worktree was chosen for it, by
/// the user or by following a task that works there.
///
/// When the project folder holds several repositories, one of them can be
/// picked for Files and Search to show on its own; Source Control shows the
/// picked repository, or else the first.
@MainActor
@Observable
public final class ProjectScope {
    public let workspaceID: UUID
    /// Main checkout → linked worktree shown instead.
    public private(set) var worktrees: [URL: URL] = [:]
    /// The main checkout of the repository picked, or nil for the project folder.
    public var selectedRepository: URL?
    @ObservationIgnored private weak var host: HostClient?

    init(host: HostClient, workspaceID: UUID) {
        self.host = host
        self.workspaceID = workspaceID
    }

    public var gitScope: GitScope { GitScope(workspaceID: workspaceID, worktrees: worktrees) }
    /// The project's repositories, once its host has sent their status.
    public var repositories: [GitRepositoryStatus]? { host?.gitStatuses[gitScope] }

    /// The project folder through the checkout chosen for its repository.
    /// Commands run here, and the editor and links resolve against it.
    public var root: URL {
        guard let folder else { return URL(filePath: "/") }
        return GitScope(workspaceID: workspaceID, worktrees: shownWorktrees).root(of: folder.filePath)
    }

    /// The folder Files and Search show: the repository picked inside the
    /// project folder, through its chosen checkout, or else `root`.
    public var filesRoot: URL {
        guard let repository = selectedNestedRepository else { return root }
        return shownWorktrees[repository] ?? repository
    }

    /// Repositories inside the project folder, which Files can show on their own.
    public var nestedRepositories: [GitRepositoryStatus] {
        (repositories ?? []).filter { isNested($0.mainRepositoryURL) }
    }

    /// The picked repository when Files shows it on its own.
    public var selectedNestedRepository: URL? {
        selectedRepository.flatMap { isNested($0) ? $0 : nil }
    }

    /// The repository Source Control shows: the one picked, else the one
    /// holding the project folder, else the first.
    public var status: GitRepositoryStatus? {
        guard let repositories else { return nil }
        return repositories.first { $0.mainRepositoryURL == selectedRepository }
            ?? repositories.first(where: holdsFolder)
            ?? repositories.first
    }

    /// Names what Files and Search show: its branch, after the repository's
    /// name for one inside the project folder. Nil while the status hasn't
    /// arrived, and for a folder that only holds repositories.
    public var title: String? {
        if let repository = selectedNestedRepository {
            guard let status = repositories?.first(where: { $0.mainRepositoryURL == repository }) else { return nil }
            return "\(status.name) · \(Self.branch(of: status))"
        }
        return repositories?.first(where: holdsFolder).map(Self.branch)
    }

    /// Shows the checkout a task works in, and picks its repository.
    public func show(_ checkout: TaskCheckout?) {
        guard let checkout else { return }
        showWorktree(checkout.worktree, of: checkout.repository)
    }

    /// Shows a repository through one of its linked worktrees, or through its
    /// main checkout for nil, and picks it.
    public func showWorktree(_ worktree: URL?, of repository: URL) {
        worktrees[repository] = worktree?.standardizedFileURL
        selectedRepository = repository
    }

    /// Makes Files and Search show a folder holding `url` when they don't:
    /// the repository it's in, or else the whole project folder.
    public func include(_ url: URL) {
        guard !filesRoot.contains(url) else { return }
        selectedRepository = nestedRepositories.first { $0.repositoryRootURL.contains(url) }?.mainRepositoryURL
    }

    /// The project folder, once the host has listed the project.
    private var folder: URL? {
        host?.workspace(workspaceID).map { URL(filePath: $0.path, directoryHint: .isDirectory) }
    }

    private func isNested(_ repository: URL) -> Bool {
        guard let folder else { return false }
        return repository.filePath != folder.filePath && folder.contains(repository)
    }

    private func holdsFolder(_ repository: GitRepositoryStatus) -> Bool {
        folder.map(repository.mainRepositoryURL.contains) ?? false
    }

    /// The worktrees chosen that the host still shows. One removed since is
    /// shown through its main checkout, as the host does.
    private var shownWorktrees: [URL: URL] {
        guard let repositories else { return worktrees }
        return worktrees.filter { repository, _ in
            repositories.first { $0.mainRepositoryURL == repository }?.isLinkedWorktree ?? true
        }
    }

    private static func branch(of status: GitRepositoryStatus) -> String {
        status.branchName ?? "Detached HEAD"
    }
}

public extension HostClient {
    /// The checkouts this device shows of one of the host's projects, shared
    /// by every page of it.
    func scope(for workspaceID: UUID) -> ProjectScope {
        if let scope = scopes[workspaceID] { return scope }
        let scope = ProjectScope(host: self, workspaceID: workspaceID)
        scopes[workspaceID] = scope
        return scope
    }
}
