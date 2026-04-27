import SwiftUI

/// What the bottom editor panel should display.
enum EditorPanelContent: Hashable, Codable {
    case file(URL)
    case diff(GitDiffReference)
}

/// Request to scroll to and highlight a match in the editor.
struct HighlightRequest: Equatable {
    let lineNumber: Int
    let columnRange: Range<Int>
}

/// Shared state for the bottom slide-up editor panel in the workspace.
@Observable
final class EditorPanel {
    var content: EditorPanelContent?
    var isDirty = false
    var isOpen = false

    /// Toggled by the header save button; observed by file editor content.
    var saveRequested = false

    /// Navigation stacks scoped to this panel's lifetime (i.e. per workspace).
    private(set) var backStack: [EditorPanelContent] = []
    private(set) var forwardStack: [EditorPanelContent] = []

    /// Pending content waiting for user confirmation to discard unsaved changes.
    var pendingContent: EditorPanelContent?

    /// Pending highlight to apply after the file loads.
    var highlightRequest: HighlightRequest?

    var showUnsavedAlert: Bool { pendingContent != nil }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func toggle() {
        isOpen.toggle()
    }

    func openFile(_ url: URL) {
        highlightRequest = nil
        navigate(to: .file(url))
    }

    func openFileAndHighlight(_ url: URL, lineNumber: Int, columnRange: Range<Int>) {
        let request = HighlightRequest(lineNumber: lineNumber, columnRange: columnRange)
        navigate(to: .file(url))
        highlightRequest = request
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
        isOpen = true
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
        isOpen = true
    }

    private func performForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = content {
            backStack.append(current)
        }
        content = next
        isOpen = true
    }
}
