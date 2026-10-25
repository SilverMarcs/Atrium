import Foundation

nonisolated struct WireGitCommit: Codable, Sendable, Hashable, Identifiable {
    var hash: String
    var message: String

    var id: String { hash }
}
