import AtriumProtocol
import Foundation

/// The Git status of the project's folders that are repositories, each seen
/// through the checkout a client chose, kept current while any client
/// follows it. Statuses come in the order of the project's folders.
@MainActor
final class GitFeed: TopicFeed {
    let scope: GitScope
    private(set) var current: HostEvent?

    private weak var workspace: Workspace?
    private var publish: ((HostEvent) -> Void)?
    private var watcher: FileSystemWatcher?
    /// The folders watched: each project folder through the worktree shown.
    private var watched: [URL] = []
    /// The reload in flight. Reloads run one at a time, so an older one can't
    /// publish over a newer one.
    private var reload: Task<Void, Never>?
    private var isStale = false

    init(scope: GitScope, workspace: Workspace) {
        self.scope = scope
        self.workspace = workspace
    }

    func start(publish: @escaping (HostEvent) -> Void) {
        self.publish = publish
        refresh()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        watched = []
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
        var shown: [URL] = []
        // Each repository's checkout shown, with the project folder it is.
        var repositories: [(root: URL, folder: String)] = []
        for path in workspace?.folders ?? [] {
            let folder = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
            guard let checkout = GitCheckout(rootedAt: folder) else {
                shown.append(folder)
                continue
            }
            let root = worktrees.first { $0.key.filePath == checkout.mainCheckoutURL.filePath }
                .map { $0.value.standardizedFileURL.resolvingSymlinksInPath() } ?? folder
            shown.append(root)
            if !repositories.contains(where: { $0.root == root }) { repositories.append((root, path)) }
        }
        if publish != nil { watch(shown) }
        var statuses = await GitRepository.shared.statusSnapshots(at: repositories.map(\.root))
        for index in statuses.indices {
            statuses[index].projectFolder = repositories.first { $0.root == statuses[index].repositoryRootURL }?.folder
        }
        guard let publish else { return }
        if case .git(_, let previous) = current, previous == statuses { return }
        let event = HostEvent.git(scope, repositories: statuses)
        current = event
        publish(event)
    }

    private func watch(_ folders: [URL]) {
        guard folders != watched else { return }
        watched = folders
        watcher?.stop()
        watcher = folders.isEmpty ? nil : FileSystemWatcher(urls: folders, fileEvents: false) { @Sendable [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}
