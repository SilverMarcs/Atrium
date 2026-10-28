import SwiftUI

/// What a diff window shows: a commit's, a stash's, or a branch comparison's
/// changes, in a project on one of the hosts.
struct GitCommitDiffSheetItem: Identifiable, Hashable, Codable {
    let project: WorkspaceRef
    let hash: String
    let message: String
    let repositoryRootURL: URL
    /// When set, this represents a stash: its files and diffs come from the stash ref.
    var stashIndex: Int?
    /// When set, this compares the committed contents of two branches.
    /// `hash` carries head; `message` carries the title text.
    var range: GitBranchRange?

    var id: String {
        if let range { return "range:\(range.base)..\(range.head)" }
        if let stashIndex { return "stash:\(stashIndex)" }
        return hash
    }

    init(project: WorkspaceRef, hash: String, message: String, repositoryRootURL: URL, stashIndex: Int? = nil) {
        self.project = project
        self.hash = hash
        self.message = message
        self.repositoryRootURL = repositoryRootURL
        self.stashIndex = stashIndex
    }

    init(project: WorkspaceRef, range: GitBranchRange, message: String, repositoryRootURL: URL) {
        self.init(project: project, hash: range.head, message: message, repositoryRootURL: repositoryRootURL)
        self.range = range
    }
}

struct GitBranchRange: Hashable, Codable {
    var base: String
    var head: String
}

struct GitCommitDiffWindow: View {
    let item: GitCommitDiffSheetItem
    @Environment(AppModel.self) private var app
    @State private var diffLoader = DiffLoadModel()
    @State private var files: [GitChangedFile] = []
    @State private var isLoading = false
    @State private var selection: GitChangedFile?
    @State private var loadError: String?

    private var shortHash: String {
        String(item.hash.prefix(7))
    }

    private var navTitle: String {
        if let range = item.range {
            return "\(range.base) → \(range.head)"
        }
        return "Changes in \(shortHash)"
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(
                        "Unable to Load Changes",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if files.isEmpty {
                    ContentUnavailableView(
                        "No Changes",
                        systemImage: "doc.richtext",
                        description: Text(item.range == nil ? "Nothing to show here." : "These branches have the same committed contents.")
                    )
                } else {
                    List(files, id: \.self, selection: $selection) { file in
                        fileRow(file)
                            .tag(file)
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 3000, max: 420)
        } detail: {
            if let selection, let project = app.project(item.project) {
                DiffBodyView(reference: reference(for: selection), project: project, loader: diffLoader)
                    .navigationTitle(selection.fileURL.lastPathComponent)
                    .navigationSubtitle(selection.repositoryRelativePath)
            } else if !files.isEmpty {
                ContentUnavailableView(
                    "Select a File",
                    systemImage: "sidebar.left",
                    description: Text("Pick a file from the sidebar to see its diff.")
                )
            }
        }
        .navigationTitle(navTitle)
        .navigationSubtitle(item.message)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 900, minHeight: 560)
        .task(id: item.id) { await load() }
    }

    @ViewBuilder
    private func fileRow(_ file: GitChangedFile) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: FileIcon.image(for: file.fileURL))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileURL.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                Text(file.repositoryRelativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            GitStatusBadge(kind: file.kind, staged: true)
        }
        .padding(.vertical, 2)
    }

    private func reference(for file: GitChangedFile) -> GitDiffReference {
        let stage: GitDiffStage
        if let range = item.range {
            stage = .range(base: range.base, head: range.head)
        } else {
            stage = .commit(hash: item.hash)
        }
        return GitDiffReference(
            repositoryRootURL: item.repositoryRootURL,
            fileURL: file.fileURL,
            repositoryRelativePath: file.repositoryRelativePath,
            stage: stage,
            kind: file.kind
        )
    }

    private func load() async {
        loadError = nil
        guard let project = app.project(item.project) else {
            loadError = "This project’s host is no longer connected."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let operation: GitOperation = if let range = item.range {
                .rangeFiles(base: range.base, head: range.head)
            } else if let stashIndex = item.stashIndex {
                .stashFiles(index: stashIndex)
            } else {
                .commitFiles(hash: item.hash)
            }
            guard case .files(let loaded) = try await project.git(operation, in: item.repositoryRootURL) else {
                throw HostClientError.unexpectedReply
            }
            files = loaded
            selection = loaded.first
        } catch {
            files = []
            selection = nil
            loadError = error.localizedDescription
        }
    }
}
