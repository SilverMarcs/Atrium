import Foundation

/// Destinations pushed within a task's detail column.
enum Route: Hashable {
    case sourceControl(UUID)
    case fileDiff(workspaceID: UUID, file: WireGitFile, isStaged: Bool)
    case commands(UUID)
}
