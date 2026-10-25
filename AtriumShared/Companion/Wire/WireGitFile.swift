import Foundation

nonisolated struct WireGitFile: Codable, Sendable, Hashable, Identifiable {
    /// Repository-relative path, unique within a section.
    var path: String
    var kind: GitChangeKind

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}
