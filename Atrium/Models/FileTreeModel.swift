import Foundation

@MainActor
@Observable
final class FileTreeModel {
    private(set) var items: [FileItem] = []
    private(set) var filteredItems: [FileItem]?
    private(set) var gitStatuses: [URL: GitChangeKind] = [:]
    private(set) var submittedSearchText = ""
    private(set) var isSearching = false
    private(set) var isTruncated = false

    var searchText = ""
    var showChangedOnly = false
    var showHiddenFiles = false

    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var directoryURL: URL?

    var changedURLs: Set<URL> { Set(gitStatuses.keys) }

    var hasActiveFilter: Bool { !submittedSearchText.isEmpty || showChangedOnly }

    var displayItems: [FileItem] { filteredItems ?? items }

    func submitSearch() {
        submittedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        refilter()
    }

    func clearSearch() {
        searchText = ""
        submittedSearchText = ""
        refilter()
    }

    func toggleChangedOnly() {
        showChangedOnly.toggle()
        refilter()
    }

    private func refilter() {
        filterTask?.cancel()

        guard hasActiveFilter else {
            filteredItems = nil
            isSearching = false
            return
        }

        let items = items
        let searchText = submittedSearchText
        let changedURLs = changedURLs
        let showChangedOnly = showChangedOnly
        isSearching = true

        filterTask = Task(priority: .userInitiated) { [weak self] in
            guard let result = try? await FileItem.filter(
                items, searchText: searchText, changedURLs: changedURLs, showChangedOnly: showChangedOnly
            ), !Task.isCancelled else { return }
            self?.filteredItems = result
            self?.isSearching = false
        }
    }

    func load(directoryURL: URL) {
        loadTask?.cancel()
        if self.directoryURL != directoryURL {
            filterTask?.cancel()
            self.directoryURL = directoryURL
            items = []
            filteredItems = nil
            gitStatuses = [:]
            isTruncated = false
            isSearching = false
        }
        let showHidden = showHiddenFiles
        loadTask = Task(priority: .userInitiated) { [weak self] in
            guard let result = try? await FileItem.buildTree(at: directoryURL, showHiddenFiles: showHidden),
                  !Task.isCancelled, let self else { return }
            var tree = result.items
            self.applyStatuses(to: &tree)
            self.items = tree
            self.isTruncated = result.isTruncated
            self.refilter()
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        filterTask?.cancel()
        isSearching = false
    }

    func refreshGit(directoryURL: URL) async {
        guard let statuses = try? await GitRepository.shared.changedFileStatuses(in: directoryURL)
        else { return }
        guard self.directoryURL == directoryURL, !Task.isCancelled else { return }
        guard statuses != gitStatuses else { return }
        gitStatuses = statuses
        var tree = items
        clearStatuses(&tree)
        applyStatuses(to: &tree)
        items = tree
        refilter()
    }

    func findItem(id: FileItem.ID, in items: [FileItem]? = nil) -> FileItem? {
        for item in items ?? self.items {
            if item.id == id { return item }
            if let children = item.children,
               let found = findItem(id: id, in: children) { return found }
        }
        return nil
    }

    // MARK: - File Operations

    func moveToTrash(url: URL, directoryURL: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        load(directoryURL: directoryURL)
    }

    func duplicate(url: URL, directoryURL: URL) {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var suffix = 2
        var destination: URL
        repeat {
            let newName = ext.isEmpty ? "\(name) \(suffix)" : "\(name) \(suffix).\(ext)"
            destination = directory.appendingPathComponent(newName)
            suffix += 1
        } while fm.fileExists(atPath: destination.path)
        try? fm.copyItem(at: url, to: destination)
        load(directoryURL: directoryURL)
    }

    @discardableResult
    func createNewFile(in parentURL: URL, directoryURL: URL) -> URL {
        let fm = FileManager.default
        var destination = parentURL.appendingPathComponent("Untitled")
        var suffix = 2
        while fm.fileExists(atPath: destination.path) {
            destination = parentURL.appendingPathComponent("Untitled \(suffix)")
            suffix += 1
        }
        fm.createFile(atPath: destination.path, contents: nil)
        load(directoryURL: directoryURL)
        return destination
    }

    @discardableResult
    func createNewFolder(in parentURL: URL, directoryURL: URL) -> URL {
        let fm = FileManager.default
        var destination = parentURL.appendingPathComponent("New Folder")
        var suffix = 2
        while fm.fileExists(atPath: destination.path) {
            destination = parentURL.appendingPathComponent("New Folder \(suffix)")
            suffix += 1
        }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: false)
        load(directoryURL: directoryURL)
        return destination
    }

    func rename(url: URL, to newName: String, directoryURL: URL) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return nil }
        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return nil }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            load(directoryURL: directoryURL)
            return destination
        } catch {
            return nil
        }
    }

    private func clearStatuses(_ tree: inout [FileItem]) {
        for i in tree.indices {
            tree[i].clearGitStatuses()
        }
    }

    private func applyStatuses(to tree: inout [FileItem]) {
        guard !gitStatuses.isEmpty else { return }
        for i in tree.indices {
            tree[i].applyGitStatuses(gitStatuses)
        }
    }
}
