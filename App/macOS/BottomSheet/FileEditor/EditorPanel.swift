import SwiftUI

/// What the bottom sheet shows: a file, a diff, or a page an agent showed.
enum EditorPanelContent: Hashable {
    case file(URL)
    case diff(GitDiffReference)
    /// A page an agent showed, in the chat that showed it.
    case page(ChatPageBlock, in: TaskRef)
}

/// Request to scroll to and highlight a match in the editor.
struct HighlightRequest: Equatable {
    let lineNumber: Int
    let columnRange: Range<Int>
}

/// The bottom sheet under a project's chats: files, diffs and the pages
/// agents showed, with back and forward through what it showed.
@Observable
final class EditorPanel {
    var content: EditorPanelContent?
    var isDirty = false
    private(set) var isOpen = false

    /// Toggled by the header save button; observed by file editor content.
    var saveRequested = false

    /// Navigation stacks scoped to this panel's lifetime (i.e. per workspace).
    private(set) var backStack: [EditorPanelContent] = []
    private(set) var forwardStack: [EditorPanelContent] = []

    /// Pending content waiting for user confirmation to discard unsaved changes.
    var pendingContent: EditorPanelContent?

    /// Pending highlight to apply after the file loads.
    var highlightRequest: HighlightRequest?

    /// Pending line to scroll to the top of the editor after the file loads.
    /// Set when opening a file from the diff view so the editor lands at
    /// roughly the same place the diff was scrolled to.
    var pendingScrollLine: Int?

    /// How this panel lays out diffs once switched in its header; nil follows
    /// the default in Settings.
    var diffLayout: DiffLayout?

    var showUnsavedAlert: Bool { pendingContent != nil }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func toggle() {
        isOpen.toggle()
    }

    func expand() {
        isOpen = true
    }

    func collapse() {
        isOpen = false
    }

    func openFile(_ url: URL, scrollToLine line: Int? = nil) {
        highlightRequest = nil
        pendingScrollLine = line
        navigate(to: .file(url))
    }

    func openFileAndHighlight(_ url: URL, lineNumber: Int, columnRange: Range<Int>) {
        let request = HighlightRequest(lineNumber: lineNumber, columnRange: columnRange)
        pendingScrollLine = nil
        navigate(to: .file(url))
        highlightRequest = request
    }

    /// Shows a page a chat's agent showed.
    func openPage(_ block: ChatPageBlock, in task: TaskRef) {
        highlightRequest = nil
        pendingScrollLine = nil
        navigate(to: .page(block, in: task))
    }

    func openDiff(_ fileURL: URL, in repositoryRoot: URL, stage: GitDiffStage = .unstaged, kind: GitChangeKind = .modified) {
        let reference = GitDiffReference(
            repositoryRootURL: repositoryRoot,
            fileURL: fileURL,
            repositoryRelativePath: fileURL.relativePath(from: repositoryRoot),
            stage: stage,
            kind: kind
        )
        navigate(to: .diff(reference))
    }

    func goBack() {
        guard canGoBack else { return }
        if isDirty {
            pendingContent = backStack.last
            pendingNavigation = .back
        } else {
            performBack()
        }
    }

    func goForward() {
        guard canGoForward else { return }
        if isDirty {
            pendingContent = forwardStack.last
            pendingNavigation = .forward
        } else {
            performForward()
        }
    }

    func close() {
        if isDirty {
            pendingContent = content // sentinel: pending == current means close
            pendingNavigation = .close
        } else {
            forceClose()
        }
    }

    func confirmDiscard() {
        let nav = pendingNavigation
        pendingContent = nil
        pendingNavigation = nil
        isDirty = false

        switch nav {
        case .back: performBack()
        case .forward: performForward()
        case .close: forceClose()
        case .navigate(let newContent):
            if let current = content {
                backStack.append(current)
            }
            forwardStack.removeAll()
            content = newContent
        case .none: break
        }
    }

    func cancelDiscard() {
        pendingContent = nil
        pendingNavigation = nil
    }

    func forceClose() {
        isDirty = false
        pendingContent = nil
        pendingNavigation = nil
        backStack.removeAll()
        forwardStack.removeAll()
        content = nil
    }

    // MARK: - Private

    private enum PendingNavigation {
        case back, forward, close
        case navigate(EditorPanelContent)
    }

    private var pendingNavigation: PendingNavigation?

    private func navigate(to newContent: EditorPanelContent) {
        expand()
        guard newContent != content else { return }
        if isDirty {
            pendingContent = newContent
            pendingNavigation = .navigate(newContent)
        } else {
            if let current = content {
                backStack.append(current)
            }
            forwardStack.removeAll()
            content = newContent
        }
    }

    private func performBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = content {
            forwardStack.append(current)
        }
        content = previous
        expand()
    }

    private func performForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = content {
            backStack.append(current)
        }
        content = next
        expand()
    }
}
