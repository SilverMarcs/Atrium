import Foundation

/// Shares workspace file navigation between terminal output and chat links.
@MainActor
enum WorkspaceLinkHandler {
    /// Returns false when the destination should use the system URL handler.
    static func openFile(_ link: String, for terminal: Terminal) -> Bool {
        guard let target = workspaceFileTarget(for: link, terminal: terminal) else { return false }
        terminal.workspace?.editorPanel.openFile(target.url, scrollToLine: target.line)
        return true
    }

    /// Resolves a clicked link to a file inside the terminal's workspace, or nil
    /// if it isn't one. Handles `file:` URLs, absolute, `~/`, and relative
    /// paths (resolved against the terminal's cwd, then the workspace root, so
    /// workspace-relative paths printed by tools resolve even when the
    /// shell's cwd is elsewhere), plus a trailing `:line[:column]` suffix
    /// from compiler-style output.
    private static func workspaceFileTarget(for link: String, terminal: Terminal) -> (url: URL, line: Int?)? {
        guard let workspace = terminal.workspace else { return nil }

        let rawPath: String
        if link.hasPrefix("file:") {
            guard let url = URL(string: link), url.isFileURL else { return nil }
            rawPath = url.path(percentEncoded: false)
        } else if link.contains("://") {
            return nil
        } else {
            rawPath = link
        }

        var candidates: [(path: String, line: Int?)] = [(rawPath, nil)]
        if let match = rawPath.wholeMatch(of: /(.+?):(\d+)(?::\d+)?/) {
            candidates.append((String(match.1), Int(match.2)))
        }

        let roots = [workspace.effectiveURL, workspace.url].map { $0.standardizedFileURL.path }
        let cwd: String
        if let directory = terminal.currentDirectory, !directory.isEmpty {
            if let url = URL(string: directory), url.isFileURL {
                cwd = url.path(percentEncoded: false)
            } else {
                cwd = directory
            }
        } else {
            cwd = workspace.directory
        }
        for (path, line) in candidates {
            let resolved: [URL]
            if path.hasPrefix("/") {
                resolved = [URL(fileURLWithPath: path)]
            } else if path == "~" || path.hasPrefix("~/") {
                resolved = [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)]
            } else {
                resolved = ([cwd] + roots).map { URL(fileURLWithPath: $0).appending(path: path) }
            }
            for url in resolved.map(\.standardizedFileURL) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                guard roots.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) else { continue }
                return (url, line)
            }
        }
        return nil
    }

}
