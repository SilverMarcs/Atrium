import Foundation

nonisolated struct DiffHunkLine: Identifiable {
    let id = UUID()
    var content: String
    var kind: GitDiffLineKind?  // nil = context line
    var oldLineNumber: Int?
    var newLineNumber: Int?
}
