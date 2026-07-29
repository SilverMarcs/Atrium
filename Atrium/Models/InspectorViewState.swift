import Foundation

@Observable
final class InspectorViewState {
    var selectedTab: InspectorTab = .files
    var fileTree = FileTreeInspectorState()
    var search = SearchInspectorState()
    var git = GitInspectorState()
    var selectedCommand: Terminal?

    func revealInFileTree(_ url: URL, relativeTo rootURL: URL) {
        // Expand all ancestor folders
        var parent = url.deletingLastPathComponent()
        while parent.path.hasPrefix(rootURL.path) && parent != rootURL {
            fileTree.expandedIDs.insert(parent.path)
            parent = parent.deletingLastPathComponent()
        }
        selectedTab = .files
        // Delay selection so the FileTreeView's List is rendered first
        DispatchQueue.main.async { [self] in
            fileTree.selectedID = url.path
        }
    }
}

/// A selection value paired with the identity of the per-workspace state
/// object that owns it. Inspector views keep a stable SwiftUI identity across
/// workspace switches (re-keying them with .id flickers the toolbar), so a
/// plain `.onChange(of: state.selectedID)` also fires when the whole state
/// object is swapped for another workspace's. Handlers compare `owner` to tell
/// an explicit selection change (same owner → open the bottom panel) from a
/// workspace switch (different owner → leave the panel as that workspace left it).
struct InspectorSelection<Value: Equatable>: Equatable {
    let owner: ObjectIdentifier
    let selection: Value

    init(_ owner: AnyObject, _ selection: Value) {
        self.owner = ObjectIdentifier(owner)
        self.selection = selection
    }
}

@Observable
final class FileTreeInspectorState {
    var model = FileTreeModel()
    var selectedID: FileItem.ID?
    var expandedIDs: Set<String> = []
    var savedExpandedIDs: Set<String>?
    var searchFocusTrigger = 0
    var renamingID: String?
}

@Observable
final class SearchInspectorState {
    var model = SearchInspectorModel()
    var expandedIDs: Set<String> = []
    var selectedID: String?
    var searchFocusTrigger = 0
}

enum GitInspectorDiscardTarget {
    case files([GitChangedFile], GitRepositoryStatusSnapshot)
    case all(GitRepositoryStatusSnapshot)
}

struct PendingBranchSwitch {
    var branch: String
    var repositoryRootURL: URL
}

@Observable
final class GitInspectorState {
    var model = GitInspectorModel()
    /// Per-repository worktree context: main repository root → linked worktree root.
    /// Session-only; a repo with no entry is viewed through its main worktree.
    var worktreeOverrides: [URL: URL] = [:]
    var selectedRepoURL: URL?
    var selectedFileID: String?
    var commitMessage = ""
    var discardTarget: GitInspectorDiscardTarget?
    var pendingBranchSwitch: PendingBranchSwitch?
    var showNewBranchSheet = false
    var newBranchName = ""
    var showStashAlert = false
    var stashMessage = ""
    var unpushedExpanded = true
    var stagedExpanded = true
    var unstagedExpanded = true
    var showPushUpstreamAlert = false
    var showPullRebaseAlert = false
    var showPullConflictAlert = false
    var showStashConflictAlert = false
    var showRenameCommitAlert = false
    var renameCommitMessage = ""
    var showUndoLastCommitAlert = false
    var showSyncWithBranchSheet = false
    var showCommitLogSheet = false
    var showBranchListSheet = false
    var showStashListSheet = false
    var branchPendingDelete: GitBranchInfo?
}

struct GitCommitDiffSheetItem: Identifiable, Hashable, Codable {
    let hash: String
    let message: String
    let repositoryRootURL: URL
    let preloadedFiles: [GitChangedFile]?
    /// When set, this represents a stash; the sheet will load its file list
    /// via `git stash show` and individual file diffs via the stash ref.
    let stashIndex: Int?
    /// When set, this represents a branch-to-branch comparison (three-dot diff).
    /// `hash` carries head; `message` carries the title text.
    let range: GitBranchRange?
    var id: String {
        if let range { return "range:\(range.base)...\(range.head)" }
        if let stashIndex { return "stash:\(stashIndex)" }
        return hash
    }

    init(hash: String, message: String, repositoryRootURL: URL, preloadedFiles: [GitChangedFile]?, stashIndex: Int? = nil) {
        self.hash = hash
        self.message = message
        self.repositoryRootURL = repositoryRootURL
        self.preloadedFiles = preloadedFiles
        self.stashIndex = stashIndex
        self.range = nil
    }

    init(range: GitBranchRange, message: String, repositoryRootURL: URL) {
        self.hash = range.head
        self.message = message
        self.repositoryRootURL = repositoryRootURL
        self.preloadedFiles = nil
        self.stashIndex = nil
        self.range = range
    }
}

struct GitBranchRange: Hashable, Codable {
    var base: String
    var head: String
}
