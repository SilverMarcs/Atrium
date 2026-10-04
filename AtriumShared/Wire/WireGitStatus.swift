import Foundation

public struct WireGitStatus: Codable, Sendable {
    public var hasRepository: Bool
    public var branchName: String?
    public var localBranches: [String]
    public var stagedFiles: [WireGitFile]
    public var unstagedFiles: [WireGitFile]
    public var unpushedCommits: [WireGitCommit]
    public var hasTrackingBranch: Bool
    public var remoteAheadCount: Int
    public var repositories: [WireGitRepository]
    public var selectedRepositoryPath: String?

    public init(
        hasRepository: Bool,
        branchName: String?,
        localBranches: [String],
        stagedFiles: [WireGitFile],
        unstagedFiles: [WireGitFile],
        unpushedCommits: [WireGitCommit],
        hasTrackingBranch: Bool,
        remoteAheadCount: Int,
        repositories: [WireGitRepository] = [],
        selectedRepositoryPath: String? = nil
    ) {
        self.hasRepository = hasRepository
        self.branchName = branchName
        self.localBranches = localBranches
        self.stagedFiles = stagedFiles
        self.unstagedFiles = unstagedFiles
        self.unpushedCommits = unpushedCommits
        self.hasTrackingBranch = hasTrackingBranch
        self.remoteAheadCount = remoteAheadCount
        self.repositories = repositories
        self.selectedRepositoryPath = selectedRepositoryPath
    }
}
