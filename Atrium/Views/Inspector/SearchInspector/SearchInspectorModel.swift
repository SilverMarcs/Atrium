import AtriumClient
import AtriumProtocol
import Foundation
import Observation
import SwiftUI

/// Find in files: the host searches the project's files, up to its caps.
@MainActor
@Observable
final class SearchInspectorModel {
    unowned let project: Project
    var query = ""
    var expandedIDs: Set<String> = []
    var selectedID: String?
    var searchFocusTrigger = 0
    private(set) var results: [FileSearchResult] = []
    private(set) var isSearching = false
    private(set) var isTruncated = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(project: Project) {
        self.project = project
    }

    func search() {
        searchTask?.cancel()
        guard !query.isEmpty else {
            results = []
            isSearching = false
            return
        }
        let query = query
        let root = project.root.filePath
        isSearching = true
        searchTask = Task {
            do {
                guard case .matches(let results, let isTruncated) = try await project.files(.search(root: root, query: query)) else { return }
                guard !Task.isCancelled else { return }
                self.results = results
                self.isTruncated = isTruncated
            } catch {
                guard !Task.isCancelled else { return }
                project.host.actionError = error.localizedDescription
            }
            isSearching = false
        }
    }

    /// The matching line with its leading whitespace trimmed and the match highlighted.
    static func highlighted(_ match: FileSearchMatch) -> AttributedString {
        let line = match.line
        let trimmed = String(line.drop(while: \.isWhitespace))
        let offset = line.count - trimmed.count
        var attributed = AttributedString(trimmed)
        attributed.font = .system(.caption, design: .monospaced)
        attributed.foregroundColor = .secondary
        let lower = match.columns.lowerBound - offset
        let upper = match.columns.upperBound - offset
        if lower >= 0, upper <= trimmed.count {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: lower)
            let end = attributed.index(attributed.startIndex, offsetByCharacters: upper)
            attributed[start..<end].foregroundColor = .accentColor
            attributed[start..<end].font = .system(.caption, design: .monospaced).bold()
        }
        return attributed
    }
}
