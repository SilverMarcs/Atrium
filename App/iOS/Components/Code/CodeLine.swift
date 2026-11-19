/// One line of a file or diff, as `CodeLinesView` shows it.
struct CodeLine: Identifiable {
    /// The line's position in what's shown.
    let id: Int
    var number: Int?
    var text: String
    /// Whether a diff adds or removes the line; nil for context and file lines.
    var kind: GitDiffLineKind?
    /// A blank standing in for the other column's line in a side-by-side diff.
    var isFiller = false

    /// A file's lines, numbered from one.
    static func lines(of text: String) -> [CodeLine] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // A final newline ends the last line rather than starting another.
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines.enumerated().map { index, line in
            CodeLine(id: index, number: index + 1, text: displayed(line))
        }
    }

    /// A diff hunk's lines, numbered as the new file has them, or the old one
    /// for removed lines.
    static func lines(of hunk: DiffHunk) -> [CodeLine] {
        hunk.lines.enumerated().map { index, line in
            CodeLine(
                id: index,
                number: line.newLineNumber ?? line.oldLineNumber,
                text: displayed(line.content[...]),
                kind: line.kind
            )
        }
    }

    /// A diff hunk's old lines and new lines, row for row, with blanks
    /// wherever one side has more lines than the other.
    static func sideBySideLines(of hunk: DiffHunk) -> (old: [CodeLine], new: [CodeLine]) {
        let rows = SideBySideDiff.rows(of: hunk.lines, kind: \.kind)
        func column(_ line: (SideBySideDiff.Row<DiffHunkLine>) -> DiffHunkLine?, number: (DiffHunkLine) -> Int?) -> [CodeLine] {
            rows.enumerated().map { index, row in
                guard let line = line(row) else {
                    // A space, so the blank row is as tall as the others.
                    return CodeLine(id: index, text: " ", isFiller: true)
                }
                return CodeLine(id: index, number: number(line), text: displayed(line.content[...]), kind: line.kind)
            }
        }
        return (column(\.old, number: \.oldLineNumber), column(\.new, number: \.newLineNumber))
    }

    /// Tabs become spaces, so every line is as wide as its characters.
    private static func displayed(_ line: Substring) -> String {
        String(line.replacing("\t", with: "    "))
    }
}
