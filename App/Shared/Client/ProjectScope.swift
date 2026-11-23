import Foundation
import Observation

/// One of a project's folders as this device shows it: a repository, seen
/// through the checkout chosen for it, or a plain folder.
struct ProjectFolder: Identifiable, Equatable, Sendable {
    /// The folder as the project lists it.
    let path: URL
    /// Its repository's status, or nil for a plain folder or before the host
    /// has sent it.
    let status: GitRepositoryStatus?

    var id: String { path.filePath }
    var name: String { path.lastPathComponent }
    /// What picks it: its repository's main checkout, or else the folder.
    var key: URL { status?.mainRepositoryURL ?? path }
    /// Where its files are: the checkout shown, or the folder itself.
    var root: URL { status?.repositoryRootURL ?? path }
}

/// Which checkouts of a project this device shows, shared by every page of the
/// project: Source Control, Files, Search and Commands. A repository is seen
/// through its main checkout unless a linked worktree was chosen for it, by
/// the user or by following a task that works there.
///
/// Every page shows the folder picked, or else the primary one. Source
/// Control shows it when it's a repository.
@MainActor
@Observable
final class ProjectScope {
    let workspaceID: UUID
    /// Main checkout → linked worktree shown instead.
    private(set) var worktrees: [URL: URL] = [:]
    /// The `ProjectFolder.key` of the folder picked, or nil for the primary one.
    var selectedFolder: URL?
    @ObservationIgnored private weak var host: HostClient?

    init(host: HostClient, workspaceID: UUID) {
        self.host = host
        self.workspaceID = workspaceID
    }

    var gitScope: GitScope { GitScope(workspaceID: workspaceID, worktrees: worktrees) }
    /// The project's repositories, once its host has sent their status.
    var repositories: [GitRepositoryStatus]? { host?.gitStatuses[gitScope] }

    /// The project's folders, the primary one first.
    var folders: [ProjectFolder] {
        let statuses = repositories ?? []
        return (host?.workspace(workspaceID)?.folders ?? []).map { path in
            ProjectFolder(path: URL(filePath: path, directoryHint: .isDirectory), status: statuses.first { $0.projectFolder == path })
        }
    }

    /// The folder every page shows: the one picked, else the primary one.
    var selected: ProjectFolder? {
        let folders = folders
        return folders.first { $0.key.filePath == selectedFolder?.filePath } ?? folders.first
    }

    /// The primary folder through the checkout chosen for it. Commands run
    /// here, and the editor and links resolve against it.
    var root: URL { folders.first?.root ?? URL(filePath: "/") }

    /// The folder Files and Search show: the one picked, through its chosen checkout.
    var filesRoot: URL { selected?.root ?? root }

    /// The repository Source Control shows: the folder picked when it's one.
    var status: GitRepositoryStatus? { selected?.status }

    /// Names what the project's pages show: its branch, after the folder's
    /// name when the project has several. Nil while the status hasn't arrived.
    var title: String? {
        guard let selected else { return nil }
        let branch = selected.status.map(Self.branch)
        guard folders.count > 1 else { return branch }
        return [selected.name, branch].compactMap(\.self).joined(separator: " · ")
    }

    /// The project's folders as pickers list them: those the task this scope
    /// follows didn't change, in the project's order, then the repositories
    /// it changed files in, the most recently changed first.
    var pickableFolders: (unchanged: [ProjectFolder], changed: [ProjectFolder]) {
        let folders = folders
        let changed = changedRepositoryURLs.compactMap { repository in folders.first { $0.status?.mainRepositoryURL == repository } }
        return (folders.filter { !changed.contains($0) }, changed)
    }

    /// Main checkouts of the repositories the followed task changed files in.
    private var changedRepositoryURLs: [URL] = []
    /// The task followed and the checkouts last shown for it.
    @ObservationIgnored private var followed: (taskID: String, checkouts: Set<TaskCheckout>)?

    /// Shows the checkouts a task works in as it opens: each repository it
    /// changed files in through the checkout it changed them in, every other
    /// one through its main checkout, and the one it works in now picked.
    func show(_ task: WireTask) {
        followed = nil
        update(task)
    }

    /// Keeps up with the task shown as it works. What's shown changes again
    /// only once it changes files in another checkout or moves to one, so a
    /// checkout picked in between stays, and an agent going back and forth
    /// between its checkouts doesn't switch them each time.
    func update(_ task: WireTask) {
        let changed = task.changedCheckouts ?? []
        let repositories = changed.map(\.repository)
        if repositories != changedRepositoryURLs { changedRepositoryURLs = repositories }
        guard let current = task.checkout else {
            followed = nil
            return
        }
        let checkouts = Set(changed + [current])
        if let followed, followed.taskID == task.id, followed.checkouts == checkouts { return }
        followed = (task.id, checkouts)
        worktrees = [:]
        for checkout in changed + [current] {
            worktrees[checkout.repository] = checkout.worktree?.standardizedFileURL
        }
        selectedFolder = current.repository
    }

    /// Shows a repository through one of its linked worktrees, or through its
    /// main checkout for nil, and picks it.
    func showWorktree(_ worktree: URL?, of repository: URL) {
        worktrees[repository] = worktree?.standardizedFileURL
        selectedFolder = repository
    }

    /// Makes Files and Search show the folder holding `url` when they don't.
    func include(_ url: URL) {
        guard !filesRoot.contains(url) else { return }
        if let folder = folders.first(where: { $0.root.contains(url) }) { selectedFolder = folder.key }
    }

    private static func branch(of status: GitRepositoryStatus) -> String {
        status.branchName ?? "Detached HEAD"
    }
}

extension HostClient {
    /// The checkouts this device shows of one of the host's projects, shared
    /// by every page of it.
    func scope(for workspaceID: UUID) -> ProjectScope {
        if let scope = scopes[workspaceID] { return scope }
        let scope = ProjectScope(host: self, workspaceID: workspaceID)
        scopes[workspaceID] = scope
        return scope
    }
}
