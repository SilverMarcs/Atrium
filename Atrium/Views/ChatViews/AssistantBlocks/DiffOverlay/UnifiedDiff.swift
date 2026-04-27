import Foundation

enum UnifiedDiff {
    /// Produces a unified diff as an ordered list of context/removed/added lines.
    /// Uses Swift's built-in `CollectionDifference` for line-level diffing.
    static func lines(oldText: String?, newText: String) -> [SharedDiffLine] {
        let newLines = newText.components(separatedBy: "\n")

        guard let old = oldText, !old.isEmpty else {
            return newLines.enumerated().map { i, line in
                SharedDiffLine(content: line, kind: .added, oldLineNumber: nil, newLineNumber: i + 1)
            }
        }

        let oldLines = old.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)

        var removals = Set<Int>()
        var insertions = Set<Int>()

        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removals.insert(offset)
            case .insert(let offset, _, _):
                insertions.insert(offset)
            }
        }

        var result: [SharedDiffLine] = []
        var oi = 0, ni = 0

        while oi < oldLines.count || ni < newLines.count {
            if oi < oldLines.count && removals.contains(oi) {
                result.append(SharedDiffLine(content: oldLines[oi], kind: .removed, oldLineNumber: oi + 1, newLineNumber: nil))
                oi += 1
            } else if ni < newLines.count && insertions.contains(ni) {
                result.append(SharedDiffLine(content: newLines[ni], kind: .added, oldLineNumber: nil, newLineNumber: ni + 1))
                ni += 1
            } else if oi < oldLines.count && ni < newLines.count {
                result.append(SharedDiffLine(content: oldLines[oi], kind: nil, oldLineNumber: oi + 1, newLineNumber: ni + 1))
                oi += 1
                ni += 1
            } else {
                break
            }
        }

        return result
    }
}
