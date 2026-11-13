import AtriumProtocol
import Foundation

/// The Git checkout a folder belongs to, located from `.git` entries without spawning Git.
/// Agents relocate into linked worktrees (e.g. Claude's `.claude/worktrees/<name>`), which
/// belong to their main checkout's project rather than forming projects of their own.
nonisolated struct GitCheckout: Equatable, Sendable {
    /// Root of the repository's main checkout — the key the inspector uses for a repository.
    let mainCheckoutURL: URL
    /// Root of the linked worktree containing the folder, or nil when it's the main checkout.
    let linkedWorktreeURL: URL?

    init?(containing directoryURL: URL) {
        let fileManager = FileManager.default
        var candidate = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        while true {
            let dotGit = candidate.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    mainCheckoutURL = Self.directoryURL(candidate.path)
                    linkedWorktreeURL = nil
                    return
                }
                // A linked worktree's `.git` file names its admin directory, whose `commondir`
                // leads back to the main `.git`. Submodules have no `commondir`; bare
                // repositories have no main checkout.
                guard let adminURL = Self.adminDirectory(ofWorktree: candidate),
                      let commonDir = try? String(contentsOf: adminURL.appending(path: "commondir"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), !commonDir.isEmpty else { return nil }
                let commonURL = Self.resolve(commonDir, against: adminURL)
                guard commonURL.lastPathComponent == ".git" else { return nil }
                mainCheckoutURL = Self.directoryURL(commonURL.deletingLastPathComponent().path)
                linkedWorktreeURL = Self.directoryURL(candidate.path)
                return
            }
            guard candidate.pathComponents.count > 1 else { return nil }
            candidate = candidate.deletingLastPathComponent()
        }
    }

    /// The checkout a folder recorded a while ago is in now. When the folder
    /// was in a linked worktree that has since moved, as `git worktree move`
    /// does, it's the worktree where it went; when the worktree was removed,
    /// its repository's main checkout. `lastUsed` is when the folder was last
    /// known to be there, which tells the worktree apart from one made later
    /// under the same name.
    init?(locating directoryURL: URL, lastUsed: Date?) {
        let fileManager = FileManager.default
        let folder = directoryURL.standardizedFileURL
        guard !fileManager.fileExists(atPath: folder.path) else {
            self.init(containing: folder)
            return
        }
        // A worktree that moved or was removed is the outermost folder that's gone.
        var gone = folder
        while gone.pathComponents.count > 2, !fileManager.fileExists(atPath: gone.deletingLastPathComponent().path) {
            gone = gone.deletingLastPathComponent()
        }
        guard let around = GitCheckout(containing: gone.deletingLastPathComponent()) else { return nil }
        if around.linkedWorktreeURL == nil,
           let moved = Self.movedWorktree(named: gone.lastPathComponent, of: around.mainCheckoutURL, before: lastUsed) {
            let inside = folder.pathComponents.dropFirst(gone.pathComponents.count)
            let relocated = inside.reduce(moved) { $0.appending(path: $1, directoryHint: .isDirectory) }
            if let checkout = GitCheckout(containing: relocated) {
                self = checkout
                return
            }
        }
        self = around
    }

    /// Where a linked worktree of a repository made in a folder called `name`
    /// is now. Git names a worktree's admin directory after the folder it's
    /// made in and keeps that name when the worktree moves, so the admin
    /// directory of that name leads to it, unless it was made after `date`
    /// for another worktree.
    private static func movedWorktree(named name: String, of mainCheckout: URL, before date: Date?) -> URL? {
        let adminURL = mainCheckout.appending(path: ".git/worktrees", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory).standardizedFileURL
        if let date, let created = try? adminURL.resourceValues(forKeys: [.creationDateKey]).creationDate, created > date {
            return nil
        }
        guard let gitFile = try? String(contentsOf: adminURL.appending(path: "gitdir"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !gitFile.isEmpty else { return nil }
        let worktree = resolve(gitFile, against: adminURL).deletingLastPathComponent()
        // A worktree moved without Git leaves its admin directory naming the old folder.
        guard adminDirectory(ofWorktree: worktree)?.filePath == adminURL.filePath else { return nil }
        return directoryURL(worktree.path)
    }

    /// The admin directory a linked worktree's `.git` file names.
    private static func adminDirectory(ofWorktree worktree: URL) -> URL? {
        guard let contents = try? String(contentsOf: worktree.appending(path: ".git"), encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:")
        else { return nil }
        return resolve(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), against: worktree)
    }

    private static func resolve(_ path: String, against baseURL: URL) -> URL {
        (path.hasPrefix("/") ? URL(filePath: path) : baseURL.appending(path: path)).standardizedFileURL
    }

    /// Matches how repository roots are spelled elsewhere, so the URLs work as dictionary keys.
    private static func directoryURL(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
    }
}
