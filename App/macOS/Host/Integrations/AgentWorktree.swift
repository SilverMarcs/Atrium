import Foundation

/// A worktree for a new chat, for providers whose server can't make one: in
/// `worktrees/<four hex digits>/<repository>` of the provider's home, as
/// Codex's own `--worktree` makes them, detached at the commit the repository
/// has checked out.
@MainActor
enum AgentWorktree {
    static func make(of directory: String, in home: URL) async throws -> URL {
        let repository = URL(filePath: directory, directoryHint: .isDirectory)
        var bucket: URL
        repeat {
            bucket = home.appending(path: "worktrees/\(UUID().uuidString.prefix(4).lowercased())", directoryHint: .isDirectory)
        } while FileManager.default.fileExists(atPath: bucket.path)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        let worktree = bucket.appending(path: repository.lastPathComponent, directoryHint: .isDirectory)
        do {
            try await GitRepository.shared.addDetachedWorktree(at: worktree, from: repository)
        } catch {
            try? FileManager.default.removeItem(at: bucket)
            throw error
        }
        return worktree
    }

    /// Removes a worktree `make` made, for a chat that didn't start.
    static func remove(_ worktree: URL, of directory: String) async {
        if (try? await GitRepository.shared.deleteWorktree(at: worktree, in: URL(filePath: directory, directoryHint: .isDirectory))) != nil {
            try? FileManager.default.removeItem(at: worktree.deletingLastPathComponent())
        }
    }
}
