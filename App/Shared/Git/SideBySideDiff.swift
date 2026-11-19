import Foundation

/// Lays a diff's lines out in two columns: context lines on both sides, each
/// run of removed lines beside the added lines that replaced it, and a blank
/// on the other side wherever one column has more lines than the other.
nonisolated enum SideBySideDiff {
    struct Row<Line> {
        var old: Line?
        var new: Line?
    }

    static func rows<Line>(of lines: [Line], kind: (Line) -> GitDiffLineKind?) -> [Row<Line>] {
        var rows: [Row<Line>] = []
        var index = 0
        while index < lines.count {
            guard kind(lines[index]) != nil else {
                rows.append(Row(old: lines[index], new: lines[index]))
                index += 1
                continue
            }
            var removed: [Line] = []
            var added: [Line] = []
            while index < lines.count, let lineKind = kind(lines[index]) {
                if lineKind == .removed { removed.append(lines[index]) } else { added.append(lines[index]) }
                index += 1
            }
            for pair in 0..<max(removed.count, added.count) {
                rows.append(Row(
                    old: pair < removed.count ? removed[pair] : nil,
                    new: pair < added.count ? added[pair] : nil
                ))
            }
        }
        return rows
    }
}

/// The part of a changed line that differs from the line it replaced, found
/// by trimming what the two share at each end. Ranges count UTF-16 units.
nonisolated enum InlineDiff {
    static func ranges(old: String, new: String) -> (old: Range<Int>?, new: Range<Int>?) {
        let oldCharacters = Array(old.utf16)
        let newCharacters = Array(new.utf16)

        var prefixLength = 0
        let minimumLength = min(oldCharacters.count, newCharacters.count)
        while prefixLength < minimumLength && oldCharacters[prefixLength] == newCharacters[prefixLength] {
            prefixLength += 1
        }

        let maximumSuffixLength = min(oldCharacters.count - prefixLength, newCharacters.count - prefixLength)
        var suffixLength = 0
        while suffixLength < maximumSuffixLength,
              oldCharacters[oldCharacters.count - 1 - suffixLength] == newCharacters[newCharacters.count - 1 - suffixLength] {
            suffixLength += 1
        }

        let oldEnd = oldCharacters.count - suffixLength
        let newEnd = newCharacters.count - suffixLength
        return (
            oldEnd > prefixLength ? prefixLength..<oldEnd : nil,
            newEnd > prefixLength ? prefixLength..<newEnd : nil
        )
    }
}
