import Foundation
import SwiftUI

struct SearchFileResult: Identifiable, Equatable, Sendable {
    var id: String { relativePath }
    let fileURL: URL
    let fileName: String
    let relativePath: String
    let disambiguator: String?
    let matches: [SearchMatch]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.relativePath == rhs.relativePath
            && lhs.disambiguator == rhs.disambiguator
            && lhs.matches.count == rhs.matches.count
    }
}

struct SearchMatch: Identifiable, Sendable {
    var id: String { "\(relativePath):\(lineNumber):\(columnRange.lowerBound)" }
    let fileURL: URL
    let relativePath: String
    let lineNumber: Int
    let columnRange: Range<Int>
    let highlightedContent: AttributedString
}

@Observable
@MainActor
final class SearchInspectorModel {
    var query = ""
    private(set) var results: [SearchFileResult] = []
    private(set) var isSearching = false

    private var searchTask: Task<Void, Never>?

    func search(in directoryURL: URL) {
        searchTask?.cancel()

        guard !query.isEmpty else {
            results = []
            isSearching = false
            return
        }

        let query = query
        isSearching = true

        searchTask = Task {
            let fileResults = await SearchEngine.performSearch(query: query, directoryURL: directoryURL)

            guard !Task.isCancelled else { return }
            results = fileResults
            isSearching = false
        }
    }
}

private enum SearchEngine {
    static let maxFiles = 100
    static let maxMatches = 1000

    static func performSearch(query: String, directoryURL: URL) async -> [SearchFileResult] {
        await Task.detached(priority: .userInitiated) {
            var fileResults: [SearchFileResult] = []
            var matchCount = 0
            let basePath = directoryURL.path

            let fileURLs = collectFiles(in: directoryURL)

            for fileURL in fileURLs {
                guard !Task.isCancelled else { return [] }
                guard fileResults.count < maxFiles, matchCount < maxMatches else { break }

                guard let data = try? Data(contentsOf: fileURL),
                      let content = String(data: data, encoding: .utf8)
                else { continue }

                let relativePath = String(fileURL.path.dropFirst(basePath.count + 1))
                var matches: [SearchMatch] = []
                let lines = content.components(separatedBy: .newlines)

                for (index, line) in lines.enumerated() {
                    guard !Task.isCancelled else { return [] }
                    guard matchCount + matches.count < maxMatches else { break }

                    let trimmedLine = String(line.prefix(500))
                    if let matchRange = trimmedLine.range(of: query, options: .caseInsensitive) {
                        let colStart = trimmedLine.distance(from: trimmedLine.startIndex, to: matchRange.lowerBound)
                        let colEnd = trimmedLine.distance(from: trimmedLine.startIndex, to: matchRange.upperBound)
                        matches.append(SearchMatch(
                            fileURL: fileURL,
                            relativePath: relativePath,
                            lineNumber: index + 1,
                            columnRange: colStart..<colEnd,
                            highlightedContent: highlight(line: trimmedLine, match: matchRange)
                        ))
                    }
                }

                if !matches.isEmpty {
                    fileResults.append(SearchFileResult(
                        fileURL: fileURL,
                        fileName: fileURL.lastPathComponent,
                        relativePath: relativePath,
                        disambiguator: nil,
                        matches: matches
                    ))
                    matchCount += matches.count
                }
            }

            return assignDisambiguators(fileResults)
        }.value
    }

    private static func assignDisambiguators(_ results: [SearchFileResult]) -> [SearchFileResult] {
        let grouped = Dictionary(grouping: results, by: \.fileName)
        return results.map { result in
            guard let group = grouped[result.fileName], group.count > 1 else {
                return result
            }
            let myDirs = Array(result.relativePath.split(separator: "/").map(String.init).dropLast())
            let otherDirsList = group
                .filter { $0.relativePath != result.relativePath }
                .map { Array($0.relativePath.split(separator: "/").map(String.init).dropLast()) }

            var disambiguator: String?
            for depth in 0..<myDirs.count {
                let i = myDirs.count - 1 - depth
                let candidate = myDirs[i]
                let collision = otherDirsList.contains { other in
                    let otherI = other.count - 1 - depth
                    return otherI >= 0 && other[otherI] == candidate
                }
                if !collision {
                    disambiguator = candidate
                    break
                }
            }

            return SearchFileResult(
                fileURL: result.fileURL,
                fileName: result.fileName,
                relativePath: result.relativePath,
                disambiguator: disambiguator ?? myDirs.last,
                matches: result.matches
            )
        }
    }

    private static func highlight(line: String, match: Range<String.Index>) -> AttributedString {
        let trimmed = String(line.drop(while: \.isWhitespace))
        let offset = line.count - trimmed.count

        var attributed = AttributedString(trimmed)
        attributed.font = .system(.caption, design: .monospaced)
        attributed.foregroundColor = .secondary

        let shiftedLower = line.index(match.lowerBound, offsetBy: -offset, limitedBy: trimmed.startIndex) ?? trimmed.startIndex
        let shiftedUpper = line.index(match.upperBound, offsetBy: -offset, limitedBy: trimmed.endIndex) ?? trimmed.endIndex

        if let start = AttributedString.Index(shiftedLower, within: attributed),
           let end = AttributedString.Index(shiftedUpper, within: attributed) {
            attributed[start..<end].foregroundColor = .accentColor
            attributed[start..<end].font = .system(.caption, design: .monospaced).bold()
        }

        return attributed
    }

    private static func collectFiles(in directoryURL: URL) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if FileItem.ignoredNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }
}
