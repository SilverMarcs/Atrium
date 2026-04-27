import SwiftUI

struct FileEditorPanel: View {
    private struct FileGitState {
        var stagedKind: GitChangeKind?
        var unstagedKind: GitChangeKind?
    }

    let fileURL: URL
    let directoryURL: URL
    @Environment(EditorPanel.self) private var panel
    @State private var content: String = ""
    @State private var savedContent: String = ""
    @State private var isLoaded = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var unsupported: UnsupportedReason?
    @State private var preview: PreviewContent?
    @State private var lastModificationDate: Date?
    @State private var gutterDiff: GutterDiffResult = .empty
    @State private var gitState = FileGitState()
    @Environment(\.showInFileTree) private var showInFileTree

    private enum UnsupportedReason {
        case tooLarge(bytes: Int64)
        case binary
    }

    private enum PreviewContent {
        case image(NSImage)
    }

    /// Files larger than this are not loaded into the editor at all.
    private static let maxEditableBytes: Int64 = 5 * 1024 * 1024

    /// Image extensions that can be previewed inline.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico", "icns", "svg",
    ]

    /// Extensions that we never try to read as text — skip the load entirely.
    private static let binaryExtensions: Set<String> = [
        // audio / video
        "mp4", "mov", "avi", "mkv", "webm", "m4v", "mp3", "wav", "flac", "m4a", "aac", "ogg",
        // archives
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso",
        // databases / executables
        "sqlite", "sqlite3", "db", "pdf", "exe", "dylib", "so", "o", "a",
        // office documents
        "xlsx", "xls", "docx", "doc", "pptx", "ppt", "pages", "numbers", "key", "keynote",
        // ml / data binary
        "parquet", "arrow", "feather", "npy", "npz", "pkl", "h5", "hdf5",
        // fonts
        "ttf", "otf", "woff", "woff2",
    ]

    private var hasUnsavedChanges: Bool {
        isLoaded && content != savedContent
    }

    var body: some View {
        PanelLayout {
            Image(nsImage: fileURL.fileIcon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(fileURL.relativePath(from: directoryURL))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let unstagedKind = gitState.unstagedKind {
                GitStatusBadge(kind: unstagedKind, staged: false)
            }
            if let stagedKind = gitState.stagedKind {
                GitStatusBadge(kind: stagedKind, staged: true)
            }
            if panel.isDirty {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        } actions: {
            Button { showInFileTree(fileURL) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .help("Show in File Tree")
        } content: {
            if isLoaded {
                CodeTextEditor(
                    text: $content,
                    documentID: fileURL,
                    fileExtension: fileURL.pathExtension.lowercased(),
                    gutterDiff: gutterDiff,
                    highlightRequest: panel.highlightRequest,
                    repositoryRootURL: directoryURL,
                    onReloadFromDisk: { loadFile() },
                    onSave: { saveFile() }
                )
            } else if let preview {
                previewView(preview)
            } else if let unsupported {
                unsupportedView(unsupported)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Cannot Open File", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: fileURL) {
            loadFile()
        }
        .watchFileSystem(at: fileURL.deletingLastPathComponent(), id: fileURL) {
            reloadIfChanged()
        }
        .onChange(of: hasUnsavedChanges) { _, dirty in
            panel.isDirty = dirty
        }
        .onChange(of: panel.saveRequested) { _, requested in
            if requested {
                saveFile()
                panel.saveRequested = false
            }
        }
        .alert("Unsaved Changes", isPresented: Binding(
            get: { panel.showUnsavedAlert },
            set: { if !$0 { panel.cancelDiscard() } }
        )) {
            Button("Save") {
                saveFile()
                panel.confirmDiscard()
            }
            Button("Discard", role: .destructive) {
                panel.confirmDiscard()
            }
            Button("Cancel", role: .cancel) {
                panel.cancelDiscard()
            }
        } message: {
            Text("Do you want to save changes to \"\(fileURL.lastPathComponent)\"?")
        }
    }

    private func reloadIfChanged() {
        guard !hasUnsavedChanges, isLoaded else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modDate = attrs[.modificationDate] as? Date,
              modDate != lastModificationDate else { return }
        lastModificationDate = modDate
        do {
            let data = try Data(contentsOf: fileURL)
            guard let string = String(data: data, encoding: .utf8) else { return }
            content = string
            savedContent = string
            refreshGitState()
        } catch {}
    }

    private func loadFile() {
        content = ""
        savedContent = ""
        isLoaded = false
        errorMessage = nil
        unsupported = nil
        preview = nil
        gutterDiff = .empty
        gitState = FileGitState()
        panel.isDirty = false
        lastModificationDate = nil

        let ext = fileURL.pathExtension.lowercased()

        // Try to load previewable file types.
        if Self.imageExtensions.contains(ext) {
            if let image = NSImage(contentsOf: fileURL) {
                preview = .image(image)
            } else {
                unsupported = .binary
            }
            return
        }

        // Skip well-known binary file types entirely — never attempt to read.
        if Self.binaryExtensions.contains(ext) {
            unsupported = .binary
            return
        }

        // Refuse anything past the size cap before allocating memory.
        let fileSize: Int64
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            fileSize = Int64(values.fileSize ?? 0)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if fileSize > Self.maxEditableBytes {
            unsupported = .tooLarge(bytes: fileSize)
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            // Quick binary sniff: a NUL byte in the first 8KB means it's not text.
            let sniffCount = min(data.count, 8192)
            if data.prefix(sniffCount).contains(0) {
                unsupported = .binary
                return
            }
            guard let string = String(data: data, encoding: .utf8) else {
                unsupported = .binary
                return
            }
            content = string
            savedContent = string
            isLoaded = true
            lastModificationDate = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
            refreshGitState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func previewView(_ content: PreviewContent) -> some View {
        switch content {
        case .image(let image):
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func unsupportedView(_ reason: UnsupportedReason) -> some View {
        ContentUnavailableView {
            Label(unsupportedTitle(reason), systemImage: unsupportedSymbol(reason))
        } description: {
            Text(unsupportedDescription(reason))
        } actions: {
            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                Button("Open in Default App") {
                    NSWorkspace.shared.open(fileURL)
                }
            }
        }
    }

    private func unsupportedTitle(_ reason: UnsupportedReason) -> String {
        switch reason {
        case .tooLarge: return "File Too Large"
        case .binary: return "Preview Not Available"
        }
    }

    private func unsupportedSymbol(_ reason: UnsupportedReason) -> String {
        switch reason {
        case .tooLarge: return "doc.badge.ellipsis"
        case .binary: return "doc"
        }
    }

    private func unsupportedDescription(_ reason: UnsupportedReason) -> String {
        switch reason {
        case .tooLarge(let bytes):
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "\(fileURL.lastPathComponent) is \(formatted) — too large to open in the editor."
        case .binary:
            return "\(fileURL.lastPathComponent) can't be displayed as text."
        }
    }

    private func saveFile() {
        isSaving = true
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            savedContent = content
            refreshGitState()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func refreshGitState() {
        Task {
            do {
                async let gutter = GitRepository.shared.gutterDiff(for: fileURL, in: directoryURL)
                async let snapshots = GitRepository.shared.statusSnapshots(in: directoryURL)
                gutterDiff = try await gutter
                gitState = try await fileGitState(from: snapshots)
            } catch {
                gutterDiff = .empty
                gitState = FileGitState()
            }
        }
    }

    private func fileGitState(from snapshots: [GitRepositoryStatusSnapshot]) throws -> FileGitState {
        let standardizedURL = fileURL.standardizedFileURL
        var state = FileGitState()

        for snapshot in snapshots {
            if let stagedMatch = snapshot.stagedFiles.first(where: { $0.fileURL.standardizedFileURL == standardizedURL }) {
                state.stagedKind = stagedMatch.kind
            }
            if let unstagedMatch = snapshot.unstagedFiles.first(where: { $0.fileURL.standardizedFileURL == standardizedURL }) {
                state.unstagedKind = unstagedMatch.kind
            }
        }

        return state
    }
}
