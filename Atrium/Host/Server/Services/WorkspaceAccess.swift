import Foundation

/// What a project lets clients reach: its folder, and the linked worktrees of
/// repositories in it, wherever those live. Paths are resolved first, so
/// neither `..` nor a symbolic link leads outside.
nonisolated struct WorkspaceAccess: Sendable {
    let folder: URL

    init(directory: String) {
        folder = URL(filePath: directory, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
    }

    func allows(_ path: String) -> Bool {
        allows(URL(filePath: path))
    }

    func allows(_ url: URL) -> Bool {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix("/") else { return false }
        if folder.contains(url) { return true }
        guard let checkout = GitCheckout(containing: url), checkout.linkedWorktreeURL != nil else { return false }
        return folder.contains(checkout.mainCheckoutURL) || checkout.mainCheckoutURL.contains(folder)
    }
}
