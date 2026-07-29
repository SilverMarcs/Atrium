import SwiftUI

struct GitCommitDiffWindow: View {
    let item: GitCommitDiffSheetItem
    @State private var diffLoader = DiffLoadModel()
    @State private var files: [GitChangedFile] = []
    @State private var isLoading = false
    @State private var selection: GitChangedFile?

    private var shortHash: String {
        String(item.hash.prefix(7))
    }

    private var navTitle: String {
        if let range = item.range {
            return "\(range.base) … \(range.head)"
        }
        return "Changes in \(shortHash)"
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let selection {
                DiffBodyView(reference: reference(for: selection), loader: diffLoader)
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
        if let preloaded = item.preloadedFiles {
            files = preloaded
            selection = selection ?? preloaded.first
            return
        }
        isLoading = true
        defer { isLoading = false }
        let loaded: [GitChangedFile]
        if let range = item.range {
            loaded = (try? await GitRepository.shared.changedFiles(base: range.base, head: range.head, at: item.repositoryRootURL)) ?? []
        } else if let stashIndex = item.stashIndex {
            loaded = (try? await GitRepository.shared.stashChangedFiles(index: stashIndex, at: item.repositoryRootURL)) ?? []
        } else {
            loaded = (try? await GitRepository.shared.changedFiles(forCommit: item.hash, at: item.repositoryRootURL)) ?? []
        }
        files = loaded
        selection = selection ?? loaded.first
    }
}
