import SwiftUI

/// One changed file's diff: its hunks, or the image before and after.
struct FileDiffScreen: View {
    let file: GitChangedFile
    @State private var source: SourceControl
    @State private var loader = DiffLoadModel()
    /// The loaded hunks, kept so their highlighting survives redraws.
    @State private var hunks: [FileDiffHunk] = []
    @AppStorage(DiffLayout.key) private var defaultLayout = DiffLayout.unified
    /// This screen's layout once switched in its toolbar; nil follows Settings.
    @State private var chosenLayout: DiffLayout?

    private var layout: DiffLayout { chosenLayout ?? defaultLayout }
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
                            ForEach(hunks) { DiffHunkView(hunk: $0, layout: layout) }
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
            if !FileTypes.isImage(file.fileURL.path) {
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Side by Side", systemImage: "rectangle.split.2x1", isOn: Binding(
                        get: { layout == .sideBySide },
                        set: { chosenLayout = $0 ? .sideBySide : .unified }
                    ))
                }
            }
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
        hunks = (presentation?.hunks ?? []).map { FileDiffHunk($0, fileName: file.name) }
    }
}
