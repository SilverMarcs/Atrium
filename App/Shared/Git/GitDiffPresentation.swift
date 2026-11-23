import AtriumProtocol
import Foundation

struct GitDiffLineNumbers: Hashable {
    var old: Int?
    var new: Int?
}

/// A unified diff laid out for reading: its lines without the +/- markers,
/// with the kind and old and new numbers of each line.
struct GitDiffPresentation {
    var string: String
    var lineKinds: [Int: GitDiffLineKind]
    var lineNumbers: [Int: GitDiffLineNumbers]
    /// Blank lines standing in for the other column's extra lines, in one
    /// side of a side-by-side diff.
    var fillerLines: Set<Int> = []
    /// Each changed line's differing part from the line it replaced or
    /// replaces, in UTF-16 units.
    var inlineChanges: [Int: Range<Int>] = [:]

    /// The first line that differs, or stands in for a line that does.
    var firstChangedLine: Int? { [lineKinds.keys.min(), fillerLines.min()].compactMap { $0 }.min() }

    init(raw: String) {
        let parsed = Self.parse(raw)
        self.string = parsed.string
        self.lineKinds = parsed.lineKinds
        self.lineNumbers = parsed.lineNumbers
        for row in SideBySideDiff.rows(of: lines, kind: \.kind) {
            guard let old = row.old, let new = row.new, old.kind != nil, new.kind != nil else { continue }
            let changes = InlineDiff.ranges(old: old.text, new: new.text)
            inlineChanges[old.number] = changes.old
            inlineChanges[new.number] = changes.new
        }
    }

    init(message: String) {
        self.string = message
        self.lineKinds = [:]
        self.lineNumbers = [:]
    }

    private init(column: Column) {
        self.string = column.lines.joined(separator: "\n")
        self.lineKinds = column.lineKinds
        self.lineNumbers = column.lineNumbers
        self.fillerLines = column.fillerLines
        self.inlineChanges = column.inlineChanges
    }

    /// The old file's column and the new file's, row for row, so the two
    /// can scroll together.
    func sideBySide() -> (old: GitDiffPresentation, new: GitDiffPresentation) {
        var oldSide = Column(), newSide = Column()
        for (index, row) in SideBySideDiff.rows(of: lines, kind: \.kind).enumerated() {
            oldSide.append(row.old, at: index + 1, from: self, number: { GitDiffLineNumbers(old: $0.old, new: nil) })
            newSide.append(row.new, at: index + 1, from: self, number: { GitDiffLineNumbers(old: nil, new: $0.new) })
        }
        return (GitDiffPresentation(column: oldSide), GitDiffPresentation(column: newSide))
    }

    /// One line of the text, numbered from one.
    private struct Line {
        var number: Int
        var text: String
        var kind: GitDiffLineKind?
    }

    private var lines: [Line] {
        string.diffLines.enumerated().map { Line(number: $0 + 1, text: $1, kind: lineKinds[$0 + 1]) }
    }

    private struct Column {
        var lines: [String] = []
        var lineKinds: [Int: GitDiffLineKind] = [:]
        var lineNumbers: [Int: GitDiffLineNumbers] = [:]
        var fillerLines: Set<Int> = []
        var inlineChanges: [Int: Range<Int>] = [:]

        /// Adds `line` as row `row`, keeping only this side's line number,
        /// or a blank when the other side has a line here and this one doesn't.
        mutating func append(_ line: Line?, at row: Int, from unified: GitDiffPresentation,
                             number: (GitDiffLineNumbers) -> GitDiffLineNumbers) {
            guard let line else {
                lines.append("")
                fillerLines.insert(row)
                return
            }
            lines.append(line.text)
            lineKinds[row] = line.kind
            lineNumbers[row] = unified.lineNumbers[line.number].map(number)
            inlineChanges[row] = unified.inlineChanges[line.number]
        }
    }

    private static func parse(_ raw: String) -> (string: String, lineKinds: [Int: GitDiffLineKind], lineNumbers: [Int: GitDiffLineNumbers]) {
        guard !raw.isEmpty else { return ("", [:], [:]) }

        let lines = raw.diffLines
        var renderedLines: [String] = []
        var lineKinds: [Int: GitDiffLineKind] = [:]
        var lineNumbers: [Int: GitDiffLineNumbers] = [:]
        var oldLineNumber: Int?
        var newLineNumber: Int?

        for line in lines {
            let renderedLine: String
            let lineKind: GitDiffLineKind?
            let displayedLineNumbers: GitDiffLineNumbers

            switch line.first {
                case "+" where !line.hasPrefix("+++"):
                    renderedLine = line.dropFirst().withoutCarriageReturn
                    lineKind = .added
                    displayedLineNumbers = .init(old: nil, new: newLineNumber)
                    self.increment(&newLineNumber)
                case "-" where !line.hasPrefix("---"):
                    renderedLine = line.dropFirst().withoutCarriageReturn
                    lineKind = .removed
                    displayedLineNumbers = .init(old: oldLineNumber, new: nil)
                    self.increment(&oldLineNumber)
                case " ":
                    renderedLine = line.dropFirst().withoutCarriageReturn
                    lineKind = nil
                    displayedLineNumbers = .init(old: oldLineNumber, new: newLineNumber)
                    self.increment(&oldLineNumber)
                    self.increment(&newLineNumber)
                case "@":
                    let hunkHeader = DiffHunkHeader(line)
                    oldLineNumber = hunkHeader?.oldLineStart
                    newLineNumber = hunkHeader?.newLineStart
                    continue
                default:
                    if line.hasPrefix("diff --git ") || line.hasPrefix("index ")
                        || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                        || line.hasPrefix("old mode ") || line.hasPrefix("new mode ")
                        || line.hasPrefix("new file mode ") || line.hasPrefix("deleted file mode ")
                        || line.hasPrefix("similarity index ")
                        || line.hasPrefix("rename from ") || line.hasPrefix("rename to ")
                        || line.hasPrefix("copy from ") || line.hasPrefix("copy to ")
                        || line.hasPrefix("Binary files ")
                        || line.hasPrefix("\\ No newline at end of file")
                    { continue }

                    renderedLine = line.withoutCarriageReturn
                    lineKind = nil
                    displayedLineNumbers = .init(old: oldLineNumber, new: newLineNumber)
            }

            renderedLines.append(renderedLine)
            lineNumbers[renderedLines.count] = displayedLineNumbers
            if let lineKind {
                lineKinds[renderedLines.count] = lineKind
            }
        }

        return (renderedLines.joined(separator: "\n"), lineKinds, lineNumbers)
    }

    private static func increment(_ value: inout Int?) {
        guard let v = value else { return }
        value = v + 1
    }
}

private struct DiffHunkHeader {
    let oldLineStart: Int
    let newLineStart: Int

    init?(_ line: String) {
        guard line.hasPrefix("@@ -") else { return nil }
        let components = line.split(separator: " ").filter { $0 != "@@" }
        guard components.count >= 2 else { return nil }

        let oldStart = Self.parseLineStart(components[0], expectedPrefix: "-")
        let newStart = Self.parseLineStart(components[1], expectedPrefix: "+")
        guard let oldStart, let newStart else { return nil }
        self.oldLineStart = oldStart
        self.newLineStart = newStart
    }

    private static func parseLineStart(_ component: Substring, expectedPrefix: Character) -> Int? {
        guard component.first == expectedPrefix else { return nil }
        let numbers = component.dropFirst().split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        return numbers.first.flatMap { Int(String($0)) }
    }
}
