import Foundation

enum ToolKind: String, Codable, Sendable {
    case read, edit, delete, move, search, execute, think, fetch, other

    var symbolName: String {
        switch self {
        case .read: "doc.text"
        case .edit: "pencil"
        case .delete: "trash"
        case .move: "arrow.right.doc.on.clipboard"
        case .search: "magnifyingglass"
        case .execute: "terminal"
        case .think: "brain"
        case .fetch: "globe"
        case .other: "wrench.and.screwdriver"
        }
    }
}
