import AtriumClient
import AtriumProtocol
import SwiftUI

/// One changed file's diff: its hunks, or the image before and after.
struct FileDiffScreen: View {
    let file: GitChangedFile
    @State private var source: SourceControl
    @State private var loader = DiffLoadModel()
    /// The loaded hunks, kept so their highlighting survives redraws.
    @State private var hunks: [(header: String, listing: CodeListing)] = []
    private let reference: GitDiffReference

    init(host: HostClient, workspaceID: UUID, file: GitChangedFile, repository: URL, isStaged: Bool) {
        self.file = file
        _source = State(initialValue: SourceControl(host: host, workspaceID: workspaceID))
        reference = GitDiffReference(
            repositoryRootURL: repository,
            fileURL: file.fileURL,
            repositoryRelativePath: file.repositoryRelativePath,
            stage: isStaged ? .staged : .unstaged,
            kind: file.kind
        )
    }

    var body: some View {
        Group {
            switch loader.phase {
            case .idle, .loading:
                ProgressView()
            case .text:
                if hunks.isEmpty {
                    ContentUnavailableView("No Changes", systemImage: "doc.plaintext")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(hunks, id: \.listing.id) { DiffHunkView(header: $0.header, listing: $0.listing) }
                        }
                        .padding(.vertical, 8)
                    }
                }
            case .image(let old, let new):
                ImageDiffView(old: old, new: new, kind: file.kind)
            case .message(let message):
                ContentUnavailableView("No Diff", systemImage: "doc.plaintext", description: Text(message))
            }
        }
        .navigationTitle(file.name)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: Route.file(source.workspace, path: file.fileURL.path(percentEncoded: false))) {
                    Label("Open File", systemImage: "arrow.up.forward.square")
                }
            }
        }
        .task(id: file) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        await loader.reloadInPlace(reference, from: source)
        guard case .text(_, let presentation) = loader.phase else { return }
        hunks = (presentation?.hunks ?? []).map { hunk in
            (hunk.header, CodeListing(lines: CodeLine.lines(of: hunk), fileName: file.name))
        }
    }
}
