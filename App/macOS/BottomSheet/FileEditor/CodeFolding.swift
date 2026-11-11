import Foundation

struct FoldRegion: Equatable {
    let startLine: Int // 1-based
    let endLine: Int   // 1-based, inclusive (the closing brace line)
    let closing: String // text shown after the ellipsis when folded (e.g. "}", "*/")
}

final class FoldingManager {
    private(set) var regions: [FoldRegion] = []
    private(set) var foldedStartLines: Set<Int> = []
    private var regionsByStartLine: [Int: FoldRegion] = [:]

    /// Line start character indices for fast line number lookup
    private(set) var lineStarts: [Int] = [0]

    func recompute(for text: String) {
        // Build line starts
        lineStarts = [0]
        for (i, c) in text.unicodeScalars.enumerated() where c == "\n" {
            lineStarts.append(i + 1)
        }

        // Detect fold regions
        regions = Self.detectFoldRegions(in: text)
        regionsByStartLine = Dictionary(regions.map { ($0.startLine, $0) }, uniquingKeysWith: { _, last in last })

        // Prune any folded lines whose regions no longer exist
        foldedStartLines = foldedStartLines.filter { regionsByStartLine[$0] != nil }
    }

    func isFoldable(_ line: Int) -> Bool { regionsByStartLine[line] != nil }
    func isFolded(_ line: Int) -> Bool { foldedStartLines.contains(line) }

    func region(startingAt line: Int) -> FoldRegion? { regionsByStartLine[line] }

    func toggleFold(_ line: Int) {
        if foldedStartLines.contains(line) {
            foldedStartLines.remove(line)
        } else if regionsByStartLine[line] != nil {
            foldedStartLines.insert(line)
        }
    }

    /// Whether this line is hidden (inside a folded region but not the start line).
    func isLineHidden(_ line: Int) -> Bool {
        for startLine in foldedStartLines {
            guard let region = regionsByStartLine[startLine] else { continue }
            if line > region.startLine && line <= region.endLine { return true }
        }
        return false
    }

    /// 1-based line number for a character index, using binary search.
    func lineNumber(forCharacterIndex index: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    // MARK: - Detection

    /// Detects fold regions from brace matching, skipping braces inside strings and comments.
    static func detectFoldRegions(in text: String) -> [FoldRegion] {
        let lines = text.components(separatedBy: "\n")
        var regions: [FoldRegion] = []
        var braceStack: [Int] = [] // line numbers of unmatched '{'
        var inBlockComment = false
        var blockCommentStart: Int?
        var inString = false
        var stringDelim: Character = "\""

        for (lineIdx, line) in lines.enumerated() {
            let lineNum = lineIdx + 1
            let chars = Array(line)
            var i = 0

            while i < chars.count {
                let c = chars[i]
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

                if inBlockComment {
                    if c == "*" && next == "/" {
                        inBlockComment = false
                        if let start = blockCommentStart, lineNum > start + 1 {
                            regions.append(FoldRegion(startLine: start, endLine: lineNum, closing: "*/"))
                        }
                        blockCommentStart = nil
                        i += 2; continue
                    }
                    i += 1; continue
                }

                if inString {
                    if c == "\\" { i += 2; continue }
                    if c == stringDelim { inString = false }
                    i += 1; continue
                }

                if c == "/" && next == "/" { break }
                if c == "/" && next == "*" {
                    inBlockComment = true; blockCommentStart = lineNum; i += 2; continue
                }
                if c == "\"" || c == "'" || c == "`" {
                    inString = true; stringDelim = c; i += 1; continue
                }

                if c == "{" {
                    braceStack.append(lineNum)
                } else if c == "}" {
                    if let openLine = braceStack.popLast(), lineNum > openLine {
                        regions.append(FoldRegion(startLine: openLine, endLine: lineNum, closing: "}"))
                    }
                }

                i += 1
            }
        }

        return regions.sorted { $0.startLine < $1.startLine }
    }
}
