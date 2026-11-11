import Foundation

nonisolated struct DiffHunk: Identifiable {
    let id = UUID()
    var header: String           // e.g. "@@ -445,15 +439,15 @@ ResourceName"
    var lines: [DiffHunkLine]
    /// The raw patch text for this hunk (header + diff lines), used for git apply
    var patchText: String
}
