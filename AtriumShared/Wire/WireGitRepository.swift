import Foundation

public struct WireGitRepository: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var displayName: String
    public var branchName: String?

    public init(path: String, displayName: String, branchName: String?) {
        self.path = path
        self.displayName = displayName
        self.branchName = branchName
    }
}
