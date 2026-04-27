import AppKit
import Foundation

enum GitDiffStage: Hashable, Codable {
    case staged
    case unstaged
    case commit(hash: String)

    var displayName: String {
        switch self {
            case .staged: "Staged Changes"
            case .unstaged: "Changes"
            case .commit(let hash): "Commit \(String(hash.prefix(7)))"
        }
    }
}

enum GitDiffLineKind: Hashable {
    case added
    case removed

    var color: NSColor {
        switch self {
            case .added: NSColor.systemGreen
            case .removed: NSColor.systemRed
        }
    }
}

struct GitDiffLineNumbers: Hashable {
    var old: Int?
    var new: Int?
}

struct GitDiffReference: Hashable, Codable {
    var repositoryRootURL: URL
    var fileURL: URL
    var repositoryRelativePath: String
    var stage: GitDiffStage
    var kind: GitChangeKind
}

// MARK: - Gutter Change Markers

enum GutterChangeKind: Hashable {
    case added
    case modified
    case deleted

    var color: NSColor {
        switch self {
            case .added: NSColor(srgbRed: 0.35, green: 0.62, blue: 0.35, alpha: 0.75)
            case .modified: NSColor(srgbRed: 0.35, green: 0.52, blue: 0.75, alpha: 0.75)
            case .deleted: NSColor(srgbRed: 0.72, green: 0.35, blue: 0.35, alpha: 0.75)
        }
    }
}

enum GutterHunkStage: Hashable {
    case staged
    case unstaged
}

struct GutterChangeMarker: Hashable {
    var kind: GutterChangeKind
    var stage: GutterHunkStage

    var color: NSColor {
        switch stage {
        case .staged:
            switch kind {
            case .added: .systemGreen
            case .modified: .systemBlue
            case .deleted: .systemRed
            }
        case .unstaged:
            kind.color
        }
    }
}

struct GutterDiffHunk {
    var newStart: Int
    var newCount: Int
    var oldStart: Int
    var oldCount: Int
    var kind: GutterChangeKind
    var stage: GutterHunkStage
    var oldContent: String
    var header: String
    var patchText: String
}

struct GutterDiffResult {
    var markers: [Int: GutterChangeMarker]
    var hunks: [GutterDiffHunk]
    static let empty = GutterDiffResult(markers: [:], hunks: [])
}

enum GutterDiffParser {
    static func parse(_ raw: String, stage: GutterHunkStage) -> GutterDiffResult {
        guard !raw.isEmpty else { return .empty }

        var markers: [Int: GutterChangeMarker] = [:]
        var hunks: [GutterDiffHunk] = []
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        var fileHeaderLines: [String] = []

        while index < lines.count && !lines[index].hasPrefix("@@") {
            fileHeaderLines.append(lines[index])
            index += 1
        }
        let fileHeader = fileHeaderLines.joined(separator: "\n")

        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("@@") else { index += 1; continue }
            guard let header = GutterHunkHeader(line) else { index += 1; continue }
            let headerLine = line
            index += 1

            var removedLines: [String] = []
            var addedLines: [String] = []
            var rawHunkLines: [String] = [headerLine]

            while index < lines.count && !lines[index].hasPrefix("@@") && !lines[index].hasPrefix("diff ") {
                let hunkLine = lines[index]
                rawHunkLines.append(hunkLine)
                if hunkLine.hasPrefix("-") && !hunkLine.hasPrefix("---") {
                    removedLines.append(String(hunkLine.dropFirst()))
                } else if hunkLine.hasPrefix("+") && !hunkLine.hasPrefix("+++") {
                    addedLines.append(String(hunkLine.dropFirst()))
                }
                index += 1
            }

            let kind: GutterChangeKind
            if !addedLines.isEmpty && !removedLines.isEmpty {
                kind = .modified
            } else if !addedLines.isEmpty {
                kind = .added
            } else if !removedLines.isEmpty {
                kind = .deleted
            } else {
                continue
            }

            if kind == .deleted {
                markers[max(header.newStart, 1)] = GutterChangeMarker(kind: .deleted, stage: stage)
            } else {
                for lineNum in header.newStart..<(header.newStart + header.newCount) {
                    markers[lineNum] = GutterChangeMarker(kind: kind, stage: stage)
                }
            }

            let patchText = fileHeader + "\n" + rawHunkLines.joined(separator: "\n") + "\n"
            hunks.append(GutterDiffHunk(
                newStart: header.newStart, newCount: header.newCount,
                oldStart: header.oldStart, oldCount: header.oldCount,
                kind: kind,
                stage: stage,
                oldContent: removedLines.joined(separator: "\n"),
                header: headerLine,
                patchText: patchText
            ))
        }

        return GutterDiffResult(markers: markers, hunks: hunks)
    }

    static func merge(unstaged: GutterDiffResult, staged: GutterDiffResult) -> GutterDiffResult {
        var markers = staged.markers
        for (line, marker) in unstaged.markers {
            markers[line] = marker
        }
        return GutterDiffResult(
            markers: markers,
            hunks: unstaged.hunks + staged.hunks
        )
    }
}

private struct GutterHunkHeader {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int

    init?(_ line: String) {
        guard line.hasPrefix("@@ -") else { return nil }
        let components = line.split(separator: " ").filter { $0 != "@@" }
        guard components.count >= 2 else { return nil }

        guard
            let (oldStart, oldCount) = Self.parseRange(components[0], expectedPrefix: "-"),
            let (newStart, newCount) = Self.parseRange(components[1], expectedPrefix: "+")
        else { return nil }

        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
    }

    private static func parseRange(_ component: Substring, expectedPrefix: Character) -> (Int, Int)? {
        guard component.first == expectedPrefix else { return nil }
        let numbers = component.dropFirst().split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = numbers.first.flatMap({ Int(String($0)) }) else { return nil }
        let count = numbers.count > 1 ? (Int(String(numbers[1])) ?? 1) : 1
        return (start, count)
    }
}

// MARK: - Diff Presentation

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

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
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
                    renderedLine = String(line.dropFirst())
                    lineKind = .added
                    displayedLineNumbers = .init(old: nil, new: newLineNumber)
                    self.increment(&newLineNumber)
                case "-" where !line.hasPrefix("---"):
                    renderedLine = String(line.dropFirst())
                    lineKind = .removed
                    displayedLineNumbers = .init(old: oldLineNumber, new: nil)
                    self.increment(&oldLineNumber)
                case " ":
                    renderedLine = String(line.dropFirst())
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

                    renderedLine = line
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

// MARK: - Hunk-based Diff (for SwiftUI rendering)

struct DiffHunkLine: Identifiable {
    let id = UUID()
    var content: String
    var kind: GitDiffLineKind?  // nil = context line
    var oldLineNumber: Int?
    var newLineNumber: Int?
}

struct DiffHunk: Identifiable {
    let id = UUID()
    var header: String           // e.g. "@@ -445,15 +439,15 @@ ResourceName"
    var lines: [DiffHunkLine]
    /// The raw patch text for this hunk (header + diff lines), used for git apply
    var patchText: String
}

struct DiffFilePresentation {
    var hunks: [DiffHunk]
    var message: String?

    init(raw: String, fileHeader: String) {
        let parsed = Self.parse(raw, fileHeader: fileHeader)
        self.hunks = parsed
        self.message = parsed.isEmpty ? "No diff available." : nil
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

private struct DiffHunkHeaderParser {
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

// MARK: - Git Commands

struct GitDiffCommand: GitCommand {
    let reference: GitDiffReference

    var arguments: [String] {
        switch reference.stage {
            case .staged:
                ["diff", "--no-color", "--no-ext-diff", "--cached", "--", reference.repositoryRelativePath]
            case .unstaged:
                ["diff", "--no-color", "--no-ext-diff", "--", reference.repositoryRelativePath]
            case .commit(let hash):
                ["show", "--format=", "--no-color", "--no-ext-diff", hash, "--", reference.repositoryRelativePath]
        }
    }

    func parse(output: String) throws -> String { output }
}

struct GitFullContextDiffCommand: GitCommand {
    let reference: GitDiffReference

    var arguments: [String] {
        switch reference.stage {
            case .staged:
                ["diff", "--no-color", "--no-ext-diff", "-U99999", "--cached", "--", reference.repositoryRelativePath]
            case .unstaged:
                ["diff", "--no-color", "--no-ext-diff", "-U99999", "--", reference.repositoryRelativePath]
            case .commit(let hash):
                ["show", "--format=", "--no-color", "--no-ext-diff", "-U99999", hash, "--", reference.repositoryRelativePath]
        }
    }

    func parse(output: String) throws -> String { output }
}
