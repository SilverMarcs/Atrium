import Foundation

public nonisolated enum GitChangeKind: String, Equatable, Hashable, Codable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case untracked
    case typeChanged
    case conflicted

    public var statusSymbol: String {
        switch self {
            case .added: "A"
            case .modified: "M"
            case .deleted: "D"
            case .renamed: "R"
            case .copied: "C"
            case .untracked: "A"
            case .typeChanged: "T"
            case .conflicted: "U"
        }
    }
}
