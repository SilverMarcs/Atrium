import SwiftUI

/// A file or a diff of the project's to show in the pane beside the chat.
enum EditorPanelContent: Hashable, Codable {
    case file(URL)
    case diff(GitDiffReference)
}

/// Request to scroll to and highlight a match in the editor.
struct HighlightRequest: Equatable {
    let lineNumber: Int
    let columnRange: Range<Int>
}

/// Opens a project's files and diffs in the pane beside the selected chat,
/// and carries where the next file should land and how diffs lay out.
@Observable
final class ProjectEditor {
    /// Shows a file or diff in the pane; the app sets this to its pane's.
    @ObservationIgnored var show: (EditorPanelContent) -> Void = { _ in }

    /// Pending highlight to apply after the file loads.
    var highlightRequest: HighlightRequest?

    /// Pending line to scroll to the top of the editor after the file loads.
    /// Set when opening a file from the diff view so the editor lands at
    /// roughly the same place the diff was scrolled to.
    var pendingScrollLine: Int?

    /// How this project lays out diffs once switched in the toolbar; nil
    /// follows the default in Settings.
    var diffLayout: DiffLayout?

    func openFile(_ url: URL, scrollToLine line: Int? = nil) {
        highlightRequest = nil
        pendingScrollLine = line
        show(.file(url))
    }

    func openFileAndHighlight(_ url: URL, lineNumber: Int, columnRange: Range<Int>) {
        pendingScrollLine = nil
        highlightRequest = HighlightRequest(lineNumber: lineNumber, columnRange: columnRange)
        show(.file(url))
    }

    func openDiff(_ fileURL: URL, in repositoryRoot: URL, stage: GitDiffStage = .unstaged, kind: GitChangeKind = .modified) {
        show(.diff(GitDiffReference(
            repositoryRootURL: repositoryRoot,
            fileURL: fileURL,
            repositoryRelativePath: fileURL.relativePath(from: repositoryRoot),
            stage: stage,
            kind: kind
        )))
    }
}
