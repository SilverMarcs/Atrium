import Foundation

public struct WireGitCommit: Codable, Sendable, Hashable, Identifiable {
    public var hash: String
    public var shortHash: String
    public var message: String

    public var id: String { hash }

    public init(hash: String, shortHash: String, message: String) {
        self.hash = hash
        self.shortHash = shortHash
        self.message = message
    }
}
