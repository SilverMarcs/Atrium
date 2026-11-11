import Foundation

nonisolated enum GitDiffLineKind: Hashable, Sendable {
    case added
    case removed
}
