import SwiftUI

struct DiffPanel: View {
    let reference: GitDiffReference
    let project: Project
    @State private var loader = DiffLoadModel()
    @State private var scrollAnchor = DiffScrollAnchor()
    @AppStorage(DiffLayout.key) private var defaultLayout = DiffLayout.unified

    /// This panel's layout: Settings' default until switched in the header.
    private var layout: DiffLayout {
        project.editor.diffLayout ?? defaultLayout
    }

    private var isImageFile: Bool {
        reference.fileURL.isPreviewableImage
    }

    private var headerStats: [Int: GitDiffLineKind]? {
        if case .text(let presentation, _) = loader.phase, !presentation.lineKinds.isEmpty {
            return presentation.lineKinds
        }
        return nil
    }

    var body: some View {
        DiffBodyView(reference: reference, project: project, loader: loader, layout: layout, scrollAnchor: scrollAnchor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem {
                    title
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
                ToolbarItemGroup {
                    if !isImageFile {
                        DiffLayoutToggle(layout: layout) { project.editor.diffLayout = $0 }
                    }
                    Button("Open File", systemImage: "arrow.up.forward.square") {
                        project.editor.openFile(reference.fileURL, scrollToLine: scrollAnchor.currentNewFileLine())
                    }
                    .help("Open File")
                }
            }
    }

    private var title: some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIcon.image(for: reference.fileURL))
                .resizable()
                .frame(width: 16, height: 16)
            Text(reference.fileURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
            GitStatusBadge(kind: reference.kind, staged: reference.stage != .unstaged)
            if !isImageFile, let stats = headerStats {
                diffStats(stats)
            }
        }
        .padding(.horizontal, 4)
        .help(reference.repositoryRelativePath)
    }

    @ViewBuilder
    private func diffStats(_ lineKinds: [Int: GitDiffLineKind]) -> some View {
        LineCounts(added: lineKinds.values.filter { $0 == .added }.count,
                   removed: lineKinds.values.filter { $0 == .removed }.count)
            .font(.caption.monospacedDigit())
    }
}

struct DiffBodyView: View {
    let reference: GitDiffReference
    let project: Project
    let loader: DiffLoadModel
    let layout: DiffLayout
    var scrollAnchor: DiffScrollAnchor?
    @State private var columnLink = DiffColumnLink()

    private var fileExtension: String {
        reference.fileURL.pathExtension.lowercased()
    }

    private var hunkTarget: HunkTarget {
        HunkTarget(project: project, repository: reference.repositoryRootURL)
    }

    var body: some View {
        Group {
            switch loader.phase {
            case .idle, .loading:
                Color.clear
            case .image(let old, let new):
                ImageDiffView(old: old, new: new, kind: reference.kind)
            case .text(let presentation, let file):
                if presentation.string.isEmpty {
                    ContentUnavailableView {
                        Text("No diff available.")
                            .foregroundStyle(.secondary)
                    }
                } else if presentation.lineKinds.isEmpty {
                    ContentUnavailableView {
                        Text(presentation.string)
                            .foregroundStyle(.secondary)
                    }
                } else if layout == .sideBySide {
                    sideBySide(presentation.sideBySide(), hunks: file?.hunks ?? [])
                        // Scrolls on under the toolbar, which insets it.
                        .ignoresSafeArea(.container, edges: .top)
                } else {
                    CodeTextEditor(
                        presentation: presentation,
                        fileExtension: fileExtension,
                        hunks: file?.hunks ?? [],
                        reference: reference,
                        hunkTarget: hunkTarget,
                        scrollAnchor: scrollAnchor,
                        onReload: reload
                    )
                    .ignoresSafeArea(.container, edges: .top)
                }
            case .message(let text):
                ContentUnavailableView {
                    Text(text)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: reference, initial: true) { _, newReference in
            loader.load(newReference, from: project.git.model)
        }
    }

    /// The old file on the left and the new one on the right, scrolling
    /// together. Long lines always wrap, and each row grows to its taller
    /// side, so the two stay level.
    private func sideBySide(_ columns: (old: GitDiffPresentation, new: GitDiffPresentation), hunks: [DiffHunk]) -> some View {
        HStack(spacing: 0) {
            CodeTextEditor(
                presentation: columns.old,
                fileExtension: fileExtension,
                hunks: hunks,
                reference: reference,
                hunkTarget: hunkTarget,
                column: DiffColumn(side: .old, link: columnLink),
                onReload: reload
            )
            Divider()
            CodeTextEditor(
                presentation: columns.new,
                fileExtension: fileExtension,
                hunks: hunks,
                reference: reference,
                hunkTarget: hunkTarget,
                scrollAnchor: scrollAnchor,
                column: DiffColumn(side: .new, link: columnLink),
                onReload: reload
            )
        }
    }

    private func reload() async {
        await loader.reloadInPlace(reference, from: project.git.model)
    }
}

/// Switches a diff between unified and side by side, lit while side by side.
struct DiffLayoutToggle: View {
    let layout: DiffLayout
    let onChange: (DiffLayout) -> Void

    private var isSideBySide: Bool { layout == .sideBySide }

    var body: some View {
        Button("Side by Side", systemImage: "rectangle.split.2x1") {
            onChange(layout.toggled)
        }
        .foregroundStyle(isSideBySide ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .accessibilityAddTraits(isSideBySide ? .isSelected : [])
        .help(isSideBySide ? "Show Unified Diff" : "Show Side by Side")
    }
}
