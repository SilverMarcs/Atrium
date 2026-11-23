import Foundation

/// One folder's entries, relisted whenever something directly inside it changes.
@MainActor
final class DirectoryFeed: TopicFeed {
    let workspaceID: UUID
    let path: String
    private(set) var current: HostEvent?

    private var publish: ((HostEvent) -> Void)?
    private var watcher: FileSystemWatcher?
    private var listing: Task<Void, Never>?

    init(workspaceID: UUID, path: String) {
        self.workspaceID = workspaceID
        self.path = path
    }

    func start(publish: @escaping (HostEvent) -> Void) {
        self.publish = publish
        let folder = path
        watcher = FileSystemWatcher(url: URL(filePath: path), latency: 0.3) { @Sendable [weak self] paths in
            // Only entries appearing, disappearing or being renamed here change the listing.
            guard paths.contains(where: { ($0 as NSString).deletingLastPathComponent == folder || $0 == folder }) else { return }
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        listing?.cancel()
        publish = nil
    }

    func refresh() {
        listing?.cancel()
        let path = path
        listing = Task {
            let entries = await FileService.entries(in: path)
            guard !Task.isCancelled, let publish else { return }
            if case .directory(_, _, let previous) = current, previous == entries { return }
            let event = HostEvent.directory(workspaceID: workspaceID, path: path, entries: entries)
            current = event
            publish(event)
        }
    }
}

/// Tells clients when a file they show changes on the host, so they reload it.
@MainActor
final class FileFeed: TopicFeed {
    let workspaceID: UUID
    let path: String
    let current: HostEvent? = nil

    private var watcher: FileSystemWatcher?
    private var modified: Date?

    init(workspaceID: UUID, path: String) {
        self.workspaceID = workspaceID
        self.path = path
    }

    func start(publish: @escaping (HostEvent) -> Void) {
        let file = path
        modified = Self.modificationDate(of: file)
        watcher = FileSystemWatcher(url: URL(filePath: path).deletingLastPathComponent(), latency: 0.3) { @Sendable [weak self] paths in
            guard paths.contains(file) else { return }
            Task { @MainActor in
                guard let self else { return }
                let modified = Self.modificationDate(of: file)
                guard modified != self.modified else { return }
                self.modified = modified
                publish(.fileChanged(workspaceID: self.workspaceID, path: file))
            }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    private nonisolated static func modificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
