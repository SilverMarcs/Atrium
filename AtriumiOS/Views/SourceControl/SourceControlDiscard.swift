import Foundation

/// A discard awaiting confirmation: some working-tree files, or all of them.
struct SourceControlDiscard: Identifiable {
    let id = UUID()
    let paths: [String]?

    var action: CompanionGitAction {
        paths.map { .discard(paths: $0) } ?? .discardAll
    }

    var message: String {
        guard let paths else { return "This discards every working-tree change. It can’t be undone." }
        if paths.count == 1, let path = paths.first {
            return "This discards your changes to “\(path)”. It can’t be undone."
        }
        return "This discards your changes to \(paths.count) files. It can’t be undone."
    }
}
