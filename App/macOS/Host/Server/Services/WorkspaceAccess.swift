import Foundation

/// What a project lets clients reach: its folders, and the linked worktrees
/// of the repositories they are, wherever those live. Paths are resolved
/// first, so neither `..` nor a symbolic link leads outside.
nonisolated struct WorkspaceAccess: Sendable {
    let folders: [URL]

    init(folders: [String]) {
        self.folders = folders.map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath() }
    }

    func allows(_ path: String) -> Bool {
        allows(URL(filePath: path))
    }

    func allows(_ url: URL) -> Bool {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix("/") else { return false }
        if folders.contains(where: { $0.contains(url) }) { return true }
        guard let checkout = GitCheckout(containing: url), checkout.linkedWorktreeURL != nil else { return false }
        return folders.contains { GitCheckout(rootedAt: $0)?.mainCheckoutURL == checkout.mainCheckoutURL }
    }
}
