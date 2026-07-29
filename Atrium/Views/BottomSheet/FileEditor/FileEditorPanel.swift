import SwiftUI

struct FileEditorPanel: View {
    private struct FileGitState {
        var stagedKind: GitChangeKind?
        var unstagedKind: GitChangeKind?
    }

    let fileURL: URL
    let directoryURL: URL
    @Environment(EditorPanel.self) private var panel
    @State private var loader = FileEditorLoadModel()
    @State private var saveError: String?
    @State private var gutterDiff: GutterDiffResult = .empty
    @State private var gitState = FileGitState()
    @State private var showingPreview = false
    @Environment(\.showInFileTree) private var showInFileTree
    @Environment(\.editorFontSize) private var editorFontSize

    private var hasUnsavedChanges: Bool {
        if case .text = loader.phase {
            return loader.content != loader.savedContent
        }
        return false
    }

    private var isMarkdownFile: Bool {
        let ext = fileURL.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
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
            if isMarkdownFile, case .text = loader.phase {
                Button {
                    showingPreview.toggle()
                } label: {
                    Image(systemName: "doc.plaintext")
                        .foregroundStyle(showingPreview ? .accent : .secondary)
                }
                .buttonStyle(.borderless)
                .help(showingPreview ? "Show Editor" : "Show Preview")
            }

            Button { showInFileTree(fileURL) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .help("Show in File Tree")
        } content: {
            switch loader.phase {
            case .text:
                if showingPreview && isMarkdownFile {
                    MarkdownPreviewView(
                        markdownText: loader.content,
                        fontSize: editorFontSize
                    )
                } else {
                    CodeTextEditor(
                        text: Binding(
                            get: { loader.content },
                            set: { loader.content = $0 }
                        ),
                        documentID: fileURL,
                        fileExtension: fileURL.pathExtension.lowercased(),
                        gutterDiff: gutterDiff,
                        highlightRequest: panel.highlightRequest,
                        scrollToLine: panel.pendingScrollLine,
                        repositoryRootURL: directoryURL,
                        onReloadFromDisk: {
                            await loader.reloadInPlace(fileURL: fileURL)
                            refreshGitState()
                        },
                        onSave: { saveFile() }
                    )
                }
            case .image(let image):
                imagePreview(image)
            case .unsupported(let reason):
                unsupportedView(reason)
            case .error(let message):
                ContentUnavailableView {
                    Label("Cannot Open File", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .idle, .loading:
                Color.clear
            }
        }
        .onChange(of: fileURL, initial: true) { _, newURL in
            showingPreview = false
            resetTransientState()
            loader.load(fileURL: newURL)
        }
        .onChange(of: loader.loadedURL) { _, _ in
            if case .text = loader.phase {
                refreshGitState()
            }
        }
        .watchFileSystem(at: fileURL.deletingLastPathComponent(), id: fileURL) {
            loader.reloadIfChanged(fileURL: fileURL)
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
            Button("Discard", role: .confirm) {
                panel.confirmDiscard()
            }
            Button("Cancel", role: .cancel) {
                panel.cancelDiscard()
            }
        } message: {
            Text("Do you want to save changes to \"\(fileURL.lastPathComponent)\"?")
        }
        .alert("Couldn't Save File", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func resetTransientState() {
        saveError = nil
        gutterDiff = .empty
        gitState = FileGitState()
        panel.isDirty = false
    }

    @ViewBuilder
    private func imagePreview(_ image: NSImage) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func unsupportedView(_ reason: FileEditorUnsupportedReason) -> some View {
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

    private func unsupportedTitle(_ reason: FileEditorUnsupportedReason) -> String {
        switch reason {
        case .tooLarge: return "File Too Large"
        case .binary: return "Preview Not Available"
        }
    }

    private func unsupportedSymbol(_ reason: FileEditorUnsupportedReason) -> String {
        switch reason {
        case .tooLarge: return "doc.badge.ellipsis"
        case .binary: return "doc"
        }
    }

    private func unsupportedDescription(_ reason: FileEditorUnsupportedReason) -> String {
        switch reason {
        case .tooLarge(let bytes):
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "\(fileURL.lastPathComponent) is \(formatted) — too large to open in the editor."
        case .binary:
            return "\(fileURL.lastPathComponent) can't be displayed as text."
        }
    }

    private func saveFile() {
        guard case .text = loader.phase else { return }
        do {
            try loader.content.write(to: fileURL, atomically: true, encoding: .utf8)
            loader.markSaved()
            refreshGitState()
        } catch {
            saveError = error.localizedDescription
        }
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
