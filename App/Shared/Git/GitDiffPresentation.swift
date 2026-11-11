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
    var hunkSeparatorLines: Set<Int>

    var firstChangedLine: Int? { lineKinds.keys.min() }

    init(raw: String) {
        let parsed = Self.parse(raw)
        self.string = parsed.string
        self.lineKinds = parsed.lineKinds
        self.lineNumbers = parsed.lineNumbers
        self.hunkSeparatorLines = parsed.hunkSeparatorLines
    }

    init(message: String) {
        self.string = message
        self.lineKinds = [:]
        self.lineNumbers = [:]
        self.hunkSeparatorLines = []
    }

    private static func parse(_ raw: String) -> (string: String, lineKinds: [Int: GitDiffLineKind], lineNumbers: [Int: GitDiffLineNumbers], hunkSeparatorLines: Set<Int>) {
        guard !raw.isEmpty else { return ("", [:], [:], []) }

        let lines = raw.diffLines
        var renderedLines: [String] = []
        var lineKinds: [Int: GitDiffLineKind] = [:]
        var lineNumbers: [Int: GitDiffLineNumbers] = [:]
        var hunkSeparatorLines: Set<Int> = []
        var hasSeenHunk = false
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
                    if hasSeenHunk, !renderedLines.isEmpty {
                        hunkSeparatorLines.insert(renderedLines.count + 1)
                    }
                    hasSeenHunk = true
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

        return (renderedLines.joined(separator: "\n"), lineKinds, lineNumbers, hunkSeparatorLines)
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
