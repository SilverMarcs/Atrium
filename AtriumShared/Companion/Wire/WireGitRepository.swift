import Foundation

/// A repository discovered inside a project folder, identified by its root path.
nonisolated struct WireGitRepository: Codable, Sendable, Hashable, Identifiable {
    var path: String
    var name: String
    /// Nil for a detached HEAD or a repository without commits.
    var branchName: String?

    var id: String { path }
}
