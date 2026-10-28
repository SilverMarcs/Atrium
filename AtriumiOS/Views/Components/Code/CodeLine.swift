/// One line of a file or diff, as `CodeLinesView` shows it.
struct CodeLine: Identifiable {
    /// The line's position in what's shown.
    let id: Int
    var number: Int?
    var text: String
    /// Whether a diff adds or removes the line; nil for context and file lines.
    var kind: GitDiffLineKind?

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

    /// Tabs become spaces, so every line is as wide as its characters.
    private static func displayed(_ line: Substring) -> String {
        String(line.replacing("\t", with: "    "))
    }
}
