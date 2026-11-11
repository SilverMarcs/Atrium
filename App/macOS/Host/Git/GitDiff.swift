import AppKit
import AtriumProtocol
import Foundation

extension GitDiffLineKind {
    var color: NSColor {
        switch self {
            case .added: NSColor.systemGreen
            case .removed: NSColor.systemRed
        }
    }
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
                // -m --first-parent so stash WIP merges show changes vs HEAD-before-stash
                // rather than the combined diff that `git show` emits for merge commits.
                ["show", "-m", "--first-parent", "--format=", "--no-color", "--no-ext-diff", hash, "--", reference.repositoryRelativePath]
            case .range(let base, let head):
                ["diff", "--no-color", "--no-ext-diff", base, head, "--", reference.repositoryRelativePath]
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
                ["show", "-m", "--first-parent", "--format=", "--no-color", "--no-ext-diff", "-U99999", hash, "--", reference.repositoryRelativePath]
            case .range(let base, let head):
                ["diff", "--no-color", "--no-ext-diff", "-U99999", base, head, "--", reference.repositoryRelativePath]
        }
    }

    func parse(output: String) throws -> String { output }
}
