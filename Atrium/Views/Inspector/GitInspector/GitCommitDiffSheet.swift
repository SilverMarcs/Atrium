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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(files, id: \.repositoryRelativePath) { file in
                                Section {
                                    DiffPanel(reference: reference(for: file))
                                        .frame(minHeight: 320)
                                        .padding(.bottom, 12)
                                } header: {
                                    fileHeader(file)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Changes in \(shortHash)")
            .navigationSubtitle(item.message)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { dismiss() }
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 720)
        .environment(\.isDetachedEditor, true)
        .task(id: item.id) { await load() }
    }

    @ViewBuilder
    private func fileHeader(_ file: GitChangedFile) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: file.fileURL.fileIcon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(file.repositoryRelativePath)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            GitStatusBadge(kind: file.kind, staged: true)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
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
