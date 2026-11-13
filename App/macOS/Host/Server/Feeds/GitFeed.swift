import AtriumProtocol
import Foundation

/// The Git status of a project's repositories, each seen through the checkout
/// a client chose, kept current while any client follows it.
@MainActor
final class GitFeed: TopicFeed {
    let scope: GitScope
    private(set) var current: HostEvent?

    private let workspacePath: String
    private var publish: ((HostEvent) -> Void)?
    private var watcher: FileSystemWatcher?
    /// The folder watched: the project folder through the worktrees shown.
    private var root: URL?
    /// The reload in flight. Reloads run one at a time, so an older one can't
    /// publish over a newer one.
    private var reload: Task<Void, Never>?
    private var isStale = false

    init(scope: GitScope, workspace: Workspace) {
        self.scope = scope
        workspacePath = workspace.directory
    }

    func start(publish: @escaping (HostEvent) -> Void) {
        self.publish = publish
        refresh()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        root = nil
        publish = nil
    }

    func refresh() {
        Task { await update() }
    }

    /// Reloads the status, publishing it before returning if it changed. A
    /// request while a reload runs waits for it and then reloads once more,
    /// together with any other requests made meanwhile.
    func update() async {
        isStale = true
        while let reload { await reload.value }
        guard isStale else { return }
        isStale = false
        // The reload clears itself, so whoever waits for it never sees it finished but still in place.
        let reload = Task {
            await load()
            self.reload = nil
        }
        self.reload = reload
        await reload.value
    }

    private func load() async {
        // A worktree chosen that has since moved or been removed is seen
        // through its main checkout, until the client chooses another.
        let worktrees = scope.worktrees.filter { FileManager.default.fileExists(atPath: $0.value.path) }
        let root = GitScope(workspaceID: scope.workspaceID, worktrees: worktrees).root(of: workspacePath)
        if publish != nil { watch(root) }
        let repositories = (try? await GitRepository.shared.statusSnapshots(in: root, worktreeOverrides: worktrees))
            .map { Self.collapseWorktreeSiblings($0, overrides: worktrees) } ?? []
        guard let publish else { return }
        if case .git(_, let previous) = current, previous == repositories { return }
        let event = HostEvent.git(scope, repositories: repositories)
        current = event
        publish(event)
    }

    private func watch(_ root: URL) {
        guard root != self.root else { return }
        self.root = root
        watcher?.stop()
        watcher = FileSystemWatcher(url: root) { @Sendable [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// A linked worktree discovered alongside its repository's main checkout (e.g.
    /// a worktree folder inside the project) is the same repository seen twice.
    /// Clients show one entry per repository: the chosen checkout when set,
    /// otherwise the main checkout. Switching between them is the branch
    /// picker's job, not the repository picker's.
    static func collapseWorktreeSiblings(_ repositories: [GitRepositoryStatus], overrides: [URL: URL]) -> [GitRepositoryStatus] {
        var byRepository: [URL: GitRepositoryStatus] = [:]
        for repository in repositories {
            let key = repository.mainRepositoryURL
            guard let existing = byRepository[key] else {
                byRepository[key] = repository
                continue
            }
            if let worktree = overrides[key]?.standardizedFileURL.resolvingSymlinksInPath() {
                if repository.repositoryRootURL == worktree { byRepository[key] = repository }
            } else if existing.isLinkedWorktree && !repository.isLinkedWorktree {
                byRepository[key] = repository
            }
        }
        return byRepository.values.sorted { $0.mainRepositoryURL.path < $1.mainRepositoryURL.path }
    }
}
