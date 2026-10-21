import Foundation

nonisolated struct GitBranchInfo: Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var isCurrent: Bool
    var upstream: String?
    var isRemote = false
    var isMergedIntoCurrentBranch = false
    var isMergedIntoDefaultBranch = false

    var id: String { "\(isRemote ? "remote" : "local")/\(name)" }
}
