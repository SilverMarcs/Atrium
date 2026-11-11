import AtriumProtocol
import Foundation

/// The Git status of a project's repositories, each seen through the checkout
/// a client chose, kept current while any client follows it.
@MainActor
final class GitFeed: TopicFeed {
    let scope: GitScope
    private(set) var current: HostEvent?

    private let root: URL
    private var publish: ((HostEvent) -> Void)?
    private var watcher: FileSystemWatcher?
    /// The reload in flight. Reloads run one at a time, so an older one can't
    /// publish over a newer one.
    private var reload: Task<Void, Never>?
    private var isStale = false

    init(scope: GitScope, workspace: Workspace) {
        self.scope = scope
        root = scope.root(of: workspace.directory)
    }

    func start(publish: @escaping (HostEvent) -> Void) {
        self.publish = publish
        watcher = FileSystemWatcher(url: root) { @Sendable [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
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
        let repositories = (try? await GitRepository.shared.statusSnapshots(in: root, worktreeOverrides: scope.worktrees))
            .map { Self.collapseWorktreeSiblings($0, overrides: scope.worktrees) } ?? []
        guard let publish else { return }
        if case .git(_, let previous) = current, previous == repositories { return }
        let event = HostEvent.git(scope, repositories: repositories)
        current = event
        publish(event)
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
