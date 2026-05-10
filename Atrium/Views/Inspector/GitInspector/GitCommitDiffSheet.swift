import SwiftUI

struct GitCommitDiffSheet: View {
    let item: GitCommitDiffSheetItem
    @Environment(\.dismiss) private var dismiss
    @State private var files: [GitChangedFile] = []
    @State private var isLoading = false

    private var shortHash: String {
        String(item.hash.prefix(7))
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if files.isEmpty {
                    ContentUnavailableView(
                        "No Changes",
                        systemImage: "doc.richtext",
                        description: Text("This commit has no file changes.")
                    )
                } else {
                    List(files, id: \.repositoryRelativePath) { file in
                        NavigationLink(value: file) {
                            fileRow(file)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Changes in \(shortHash)")
            .navigationSubtitle(item.message)
            .navigationDestination(for: GitChangedFile.self) { file in
                DiffPanel(reference: reference(for: file))
                    .navigationTitle(file.fileURL.lastPathComponent)
                    .navigationSubtitle(file.repositoryRelativePath)
                    .toolbar { doneToolbar }
            }
            .toolbar { doneToolbar }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 720)
        .environment(\.isDetachedEditor, true)
        .task(id: item.id) { await load() }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(role: .confirm) { dismiss() }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: GitChangedFile) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: file.fileURL.fileIcon)
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
        if let preloaded = item.preloadedFiles {
            files = preloaded
            return
        }
        isLoading = true
        defer { isLoading = false }
        files = (try? await GitRepository.shared.changedFiles(forCommit: item.hash, at: item.repositoryRootURL)) ?? []
    }
}
