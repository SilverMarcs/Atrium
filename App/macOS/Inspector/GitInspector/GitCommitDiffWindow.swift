import AtriumClient
import AtriumProtocol
import SwiftUI

/// What a diff window shows: a commit's changes, in a project on one of the
/// hosts.
struct GitCommitDiffSheetItem: Identifiable, Hashable, Codable {
    let project: WorkspaceRef
    let hash: String
    let message: String
    let repositoryRootURL: URL

    var id: String { hash }
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
                        description: Text("Nothing to show here.")
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
        .navigationTitle("Changes in \(shortHash)")
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
        GitDiffReference(
            repositoryRootURL: item.repositoryRootURL,
            fileURL: file.fileURL,
            repositoryRelativePath: file.repositoryRelativePath,
            stage: .commit(hash: item.hash),
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
            guard case .files(let loaded) = try await project.git(.commitFiles(hash: item.hash), in: item.repositoryRootURL) else {
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
