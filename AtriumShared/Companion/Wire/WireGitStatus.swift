import Foundation

/// Status of the repository selected for a workspace, plus every repository
/// discovered in the project folder so the companion can switch between them.
nonisolated struct WireGitStatus: Codable, Sendable, Equatable {
    var repositories: [WireGitRepository]
    /// Nil exactly when `repositories` is empty.
    var selectedRepositoryPath: String?
    var branchName: String?
    var localBranches: [String]
    var stagedFiles: [WireGitFile]
    var unstagedFiles: [WireGitFile]
    var unpushedCommits: [WireGitCommit]
    var hasTrackingBranch: Bool
    var remoteAheadCount: Int

    var hasRepository: Bool { selectedRepositoryPath != nil }

    static let empty = WireGitStatus(
        repositories: [], selectedRepositoryPath: nil, branchName: nil, localBranches: [],
        stagedFiles: [], unstagedFiles: [], unpushedCommits: [], hasTrackingBranch: false, remoteAheadCount: 0
    )
}
