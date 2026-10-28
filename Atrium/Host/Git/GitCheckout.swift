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
                guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = contents.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:")
                else { return nil }
                let adminURL = Self.resolve(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), against: candidate)
                guard let commonDir = try? String(contentsOf: adminURL.appending(path: "commondir"), encoding: .utf8)
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

    private static func resolve(_ path: String, against baseURL: URL) -> URL {
        (path.hasPrefix("/") ? URL(filePath: path) : baseURL.appending(path: path)).standardizedFileURL
    }

    /// Matches how repository roots are spelled elsewhere, so the URLs work as dictionary keys.
    private static func directoryURL(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
    }
}
