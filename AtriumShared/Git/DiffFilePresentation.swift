import Foundation

/// A file's unified diff split into hunks, with line numbers and the patch
/// text each hunk needs to be staged or discarded on its own.
nonisolated struct DiffFilePresentation {
    var hunks: [DiffHunk]
    var message: String?

    init(raw: String, fileHeader: String) {
        let parsed = Self.parse(raw, fileHeader: fileHeader)
        self.hunks = parsed
        self.message = parsed.isEmpty ? "No diff available." : nil
    }

    /// Uses everything before the first hunk as the file header.
    init(raw: String) {
        let header = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.hasPrefix("@@") }
            .joined(separator: "\n")
        self.init(raw: raw, fileHeader: header)
    }

    init(message: String) {
        self.hunks = []
        self.message = message
    }

    private static func parse(_ raw: String, fileHeader: String) -> [DiffHunk] {
        guard !raw.isEmpty else { return [] }

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var hunks: [DiffHunk] = []
        var index = 0

        // Skip file-level headers to find first hunk
        while index < lines.count && !lines[index].hasPrefix("@@") {
            index += 1
        }

        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("@@") else { index += 1; continue }

            let headerLine = line
            index += 1

            // Parse hunk header for line numbers
            let hunkHeader = DiffHunkHeaderParser(headerLine)
            var oldLine = hunkHeader?.oldStart ?? 1
            var newLine = hunkHeader?.newStart ?? 1

            var hunkLines: [DiffHunkLine] = []
            var rawHunkLines: [String] = [headerLine]

            while index < lines.count && !lines[index].hasPrefix("@@") && !lines[index].hasPrefix("diff ") {
                let l = lines[index]
                rawHunkLines.append(l)

                if l.hasPrefix("+") && !l.hasPrefix("+++") {
                    hunkLines.append(DiffHunkLine(content: String(l.dropFirst()), kind: .added, oldLineNumber: nil, newLineNumber: newLine))
                    newLine += 1
                } else if l.hasPrefix("-") && !l.hasPrefix("---") {
                    hunkLines.append(DiffHunkLine(content: String(l.dropFirst()), kind: .removed, oldLineNumber: oldLine, newLineNumber: nil))
                    oldLine += 1
                } else if l.hasPrefix(" ") {
                    hunkLines.append(DiffHunkLine(content: String(l.dropFirst()), kind: nil, oldLineNumber: oldLine, newLineNumber: newLine))
                    oldLine += 1
                    newLine += 1
                } else if l.hasPrefix("\\ No newline") {
                    // skip
                } else {
                    hunkLines.append(DiffHunkLine(content: l, kind: nil, oldLineNumber: oldLine, newLineNumber: newLine))
                }

                index += 1
            }

            let patchText = fileHeader + "\n" + rawHunkLines.joined(separator: "\n") + "\n"

            hunks.append(DiffHunk(
                header: headerLine,
                lines: hunkLines,
                patchText: patchText
            ))
        }

        return hunks
    }
}

private nonisolated struct DiffHunkHeaderParser {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int

    init?(_ line: String) {
        guard line.hasPrefix("@@ -") else { return nil }
        let components = line.split(separator: " ").filter { $0 != "@@" }
        guard components.count >= 2 else { return nil }
        guard let (os, oc) = Self.parseRange(components[0], expectedPrefix: "-"),
              let (ns, nc) = Self.parseRange(components[1], expectedPrefix: "+")
        else { return nil }
        self.oldStart = os; self.oldCount = oc
        self.newStart = ns; self.newCount = nc
    }

    private static func parseRange(_ component: Substring, expectedPrefix: Character) -> (Int, Int)? {
        guard component.first == expectedPrefix else { return nil }
        let numbers = component.dropFirst().split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = numbers.first.flatMap({ Int(String($0)) }) else { return nil }
        let count = numbers.count > 1 ? (Int(String(numbers[1])) ?? 1) : 1
        return (start, count)
    }
}
