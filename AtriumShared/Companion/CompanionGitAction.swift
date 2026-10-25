import Foundation

/// Acts on the repository currently selected for a workspace.
nonisolated enum CompanionGitAction: Codable, Sendable {
    case refresh
    case selectRepository(path: String)
    case stage(paths: [String])
    case unstage(paths: [String])
    case discard(paths: [String])
    case stageAll
    case unstageAll
    case discardAll
    case commit(message: String)
    case push
    case pull
    case fetch
    case switchBranch(name: String)
    case createBranch(name: String)
}
