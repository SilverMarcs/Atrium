import Foundation

/// A discard awaiting confirmation: some working-tree files, or all of them.
struct SourceControlDiscard: Identifiable {
    let id = UUID()
    /// Nil for every working-tree change.
    let files: [GitChangedFile]?

    var operation: GitOperation {
        guard let files else { return .discardAll }
        return .discard(
            tracked: files.filter { $0.kind != .untracked }.map(\.repositoryRelativePath),
            untracked: files.filter { $0.kind == .untracked }.map(\.repositoryRelativePath)
        )
    }

    var message: String {
        guard let files else { return "This discards every working-tree change. It can’t be undone." }
        if files.count == 1, let file = files.first {
            return "This discards your changes to “\(file.repositoryRelativePath)”. It can’t be undone."
        }
        return "This discards your changes to \(files.count) files. It can’t be undone."
    }
}
