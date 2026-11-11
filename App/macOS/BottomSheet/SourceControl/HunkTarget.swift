import AtriumProtocol
import Foundation

/// Where a diff's hunks are staged, unstaged or discarded: a repository in a
/// project, on its host.
struct HunkTarget {
    let project: Project
    let repository: URL

    func apply(_ patch: String, reverse: Bool, cached: Bool) async throws {
        _ = try await project.git(.applyPatch(patch, reverse: reverse, cached: cached), in: repository)
    }
}
