import SwiftUI

struct DiffPanel: View {
    let reference: GitDiffReference
    @State private var presentation: GitDiffPresentation?
    @State private var filePresentation: DiffFilePresentation?
    @State private var imageDiff: ImageDiffContent?
    @State private var isLoading = true

    @Environment(EditorPanel.self) private var panel

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico", "icns", "svg",
    ]

    private var isImageFile: Bool {
        Self.imageExtensions.contains(reference.fileURL.pathExtension.lowercased())
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
            if !isImageFile, let presentation, !presentation.lineKinds.isEmpty {
                diffStats(presentation.lineKinds)
            }
        } actions: {
            Button { panel.openFile(reference.fileURL) } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("Open File")
        } content: {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let imageDiff {
                ImageDiffView(content: imageDiff, kind: reference.kind)
            } else if let message = presentation?.string, presentation?.lineKinds.isEmpty == true, !message.isEmpty {
                ContentUnavailableView {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            } else if let presentation, !presentation.string.isEmpty {
                CodeTextEditor(
                    presentation: presentation,
                    fileExtension: reference.fileURL.pathExtension.lowercased(),
                    hunks: filePresentation?.hunks ?? [],
                    reference: reference,
                    onReload: { await loadDiff() }
                )
            } else {
                ContentUnavailableView {
                    Text("No diff available.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: reference) { await loadDiff() }
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

    private func loadDiff() async {
        isLoading = true

        if isImageFile {
            await loadImageDiff()
        } else {
            do {
                async let fullContext = GitRepository.shared.fullContextDiffPresentation(for: reference)
                async let hunkBased = GitRepository.shared.diffFilePresentation(for: reference)
                let (full, hunks) = try await (fullContext, hunkBased)
                presentation = full
                filePresentation = hunks
            } catch {
                presentation = GitDiffPresentation(message: "Failed to load diff: \(error.localizedDescription)")
                filePresentation = nil
            }
        }

        isLoading = false
    }

    private func loadImageDiff() async {
        let path = reference.repositoryRelativePath
        let root = reference.repositoryRootURL

        var oldImage: NSImage?
        var newImage: NSImage?

        switch reference.kind {
        case .added, .untracked:
            // No old version
            oldImage = nil
        case .deleted:
            // No new version
            newImage = nil
        default:
            break
        }

        // Load old image from git
        if reference.kind != .added && reference.kind != .untracked {
            do {
                let ref: String
                switch reference.stage {
                case .unstaged:
                    // Old = index version
                    ref = ""
                case .staged:
                    // Old = HEAD version
                    ref = "HEAD"
                case .commit(let hash):
                    ref = "\(hash)~1"
                }
                let data = try await GitRepository.shared.fileData(at: path, ref: ref, repositoryRootURL: root)
                oldImage = NSImage(data: data)
            } catch {
                // File may not exist in old version (e.g. newly added)
            }
        }

        // Load new image
        if reference.kind != .deleted {
            switch reference.stage {
            case .unstaged:
                // New = working copy
                newImage = NSImage(contentsOf: reference.fileURL)
            case .staged:
                // New = index version
                do {
                    let data = try await GitRepository.shared.fileData(at: path, ref: "", repositoryRootURL: root)
                    newImage = NSImage(data: data)
                } catch {
                    newImage = NSImage(contentsOf: reference.fileURL)
                }
            case .commit(let hash):
                do {
                    let data = try await GitRepository.shared.fileData(at: path, ref: hash, repositoryRootURL: root)
                    newImage = NSImage(data: data)
                } catch {}
            }
        }

        imageDiff = ImageDiffContent(oldImage: oldImage, newImage: newImage)
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
            // Before
            imageSide(
                image: content.oldImage,
                label: "Before",
                fallback: kind == .added || kind == .untracked ? "New file" : nil
            )
            .background(content.oldImage == nil ? Color.clear : Color.red.opacity(0.05))

            Divider()

            // After
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

