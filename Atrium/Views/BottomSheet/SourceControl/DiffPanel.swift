import SwiftUI

struct DiffPanel: View {
    let reference: GitDiffReference
    @State private var loader = DiffLoadModel()

    @Environment(EditorPanel.self) private var panel

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
        PanelLayout {
            Image(nsImage: reference.fileURL.fileIcon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(reference.repositoryRelativePath)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            GitStatusBadge(kind: reference.kind, staged: reference.stage != .unstaged)
            if !isImageFile, let stats = headerStats {
                diffStats(stats)
            }
        } actions: {
            Button { panel.openFile(reference.fileURL) } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("Open File")
        } content: {
            switch loader.phase {
            case .idle, .loading:
                Color.clear
            case .image(let oldImage, let newImage):
                ImageDiffView(content: ImageDiffContent(oldImage: oldImage, newImage: newImage), kind: reference.kind)
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
                } else {
                    CodeTextEditor(
                        presentation: presentation,
                        fileExtension: reference.fileURL.pathExtension.lowercased(),
                        hunks: file?.hunks ?? [],
                        reference: reference,
                        onReload: { loader.load(reference: reference) }
                    )
                }
            case .message(let text):
                ContentUnavailableView {
                    Text(text)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: reference, initial: true) { _, newReference in
            loader.load(reference: newReference)
        }
    }

    @ViewBuilder
    private func diffStats(_ lineKinds: [Int: GitDiffLineKind]) -> some View {
        let added = lineKinds.values.filter { $0 == .added }.count
        let removed = lineKinds.values.filter { $0 == .removed }.count
        HStack(spacing: 4) {
            if added > 0 {
                Text("+\(added)")
                    .foregroundStyle(.green)
            }
            if removed > 0 {
                Text("-\(removed)")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption.monospacedDigit())
    }
}

// MARK: - Image Diff

private struct ImageDiffContent {
    var oldImage: NSImage?
    var newImage: NSImage?
}

private struct ImageDiffView: View {
    let content: ImageDiffContent
    let kind: GitChangeKind

    var body: some View {
        HStack(spacing: 0) {
            imageSide(
                image: content.oldImage,
                label: "Before",
                fallback: kind == .added || kind == .untracked ? "New file" : nil
            )
            .background(content.oldImage == nil ? Color.clear : Color.red.opacity(0.05))

            Divider()

            imageSide(
                image: content.newImage,
                label: "After",
                fallback: kind == .deleted ? "Deleted" : nil
            )
            .background(content.newImage == nil ? Color.clear : Color.green.opacity(0.05))
        }
    }

    @ViewBuilder
    private func imageSide(image: NSImage?, label: String, fallback: String?) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)

            Divider()

            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let fallback {
                ContentUnavailableView {
                    Text(fallback)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Text("Not available")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
