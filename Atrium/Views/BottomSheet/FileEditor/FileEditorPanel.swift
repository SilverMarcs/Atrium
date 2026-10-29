import AtriumClient
import AtriumProtocol
import SwiftUI

/// A file from the project's host in the bottom panel: editable on this Mac's
/// own host, read-only on any other, and reloaded when it changes there.
struct FileEditorPanel: View {
    let fileURL: URL
    let project: Project
    @State private var loader = FileEditorLoadModel()
    @State private var saveError: String?
    @State private var gutterDiff: GutterDiffResult = .empty
    @State private var showingPreview = false
    @Environment(\.editorFontSize) private var editorFontSize

    private var panel: EditorPanel { project.editor }
    private var path: String { fileURL.filePath }

    private var isMarkdownFile: Bool {
        let ext = fileURL.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    /// The file's staged and unstaged changes, from the project's Git status.
    private var gitKinds: (staged: GitChangeKind?, unstaged: GitChangeKind?) {
        let files = project.repositories ?? []
        let standardized = fileURL.standardizedFileURL
        return (
            files.lazy.compactMap { $0.stagedFiles.first { $0.fileURL.standardizedFileURL == standardized }?.kind }.first,
            files.lazy.compactMap { $0.unstagedFiles.first { $0.fileURL.standardizedFileURL == standardized }?.kind }.first
        )
    }

    var body: some View {
        PanelLayout {
            Image(nsImage: FileIcon.image(for: fileURL))
                .resizable()
                .frame(width: 16, height: 16)
            Text(fileURL.relativePath(from: project.root))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let unstaged = gitKinds.unstaged {
                GitStatusBadge(kind: unstaged, staged: false)
            }
            if let staged = gitKinds.staged {
                GitStatusBadge(kind: staged, staged: true)
            }
            if !project.isLocal {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .help("Files on \(project.host.name) are read-only here")
            }
            if panel.isDirty {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        } actions: {
            if isMarkdownFile, case .text = loader.phase {
                Button("Preview", systemImage: "doc.plaintext") {
                    showingPreview.toggle()
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(showingPreview ? .accent : .secondary)
                .buttonStyle(.borderless)
                .help(showingPreview ? "Show Editor" : "Show Preview")
            }

            Button("Show in File Tree", systemImage: "folder") { project.reveal(fileURL) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .help("Show in File Tree")
        } content: {
            switch loader.phase {
            case .text:
                if showingPreview && isMarkdownFile {
                    MarkdownPreviewView(markdownText: loader.content, fontSize: editorFontSize)
                } else {
                    CodeTextEditor(
                        text: $loader.content,
                        documentID: fileURL,
                        fileExtension: fileURL.pathExtension.lowercased(),
                        isEditable: project.isLocal,
                        gutterDiff: gutterDiff,
                        highlightRequest: panel.highlightRequest,
                        scrollToLine: panel.pendingScrollLine,
                        hunkTarget: HunkTarget(project: project, repository: project.root),
                        onReloadFromDisk: {
                            await loader.reloadInPlace(fileURL, in: project)
                            await loadGutter()
                        },
                        onSave: save
                    )
                }
            case .image(let image):
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .tooLarge(let bytes):
                unavailable("File Too Large", systemImage: "doc.badge.ellipsis",
                            description: "\(fileURL.lastPathComponent) is \(bytes.formatted(.byteCount(style: .file))) — too large to open in the editor.")
            case .binary:
                unavailable("Preview Not Available", systemImage: "doc",
                            description: "\(fileURL.lastPathComponent) can’t be displayed as text.")
            case .error(let message):
                ContentUnavailableView("Cannot Open File", systemImage: "exclamationmark.triangle", description: Text(message))
            case .idle, .loading:
                Color.clear
            }
        }
        .onChange(of: fileURL, initial: true) { _, url in
            showingPreview = false
            saveError = nil
            gutterDiff = .empty
            panel.isDirty = false
            loader.load(url, in: project)
        }
        .task(id: fileURL) {
            await project.host.follow(.file(workspaceID: project.workspaceID, path: path))
        }
        .onChange(of: project.host.fileRevisions[.file(workspaceID: project.workspaceID, path: path)]) {
            loader.reloadIfUnchanged(fileURL, in: project)
        }
        .task(id: GutterID(url: loader.loadedURL, repositories: project.repositories)) {
            await loadGutter()
        }
        .onChange(of: loader.hasUnsavedChanges) { _, dirty in
            panel.isDirty = dirty
        }
        .onChange(of: panel.saveRequested) { _, requested in
            if requested {
                save()
                panel.saveRequested = false
            }
        }
        .alert("Unsaved Changes", isPresented: Binding(
            get: { panel.showUnsavedAlert },
            set: { if !$0 { panel.cancelDiscard() } }
        )) {
            Button("Save") {
                save()
                panel.confirmDiscard()
            }
            Button("Discard", role: .confirm) { panel.confirmDiscard() }
            Button("Cancel", role: .cancel) { panel.cancelDiscard() }
        } message: {
            Text("Do you want to save changes to “\(fileURL.lastPathComponent)”?")
        }
        .alert("Couldn’t Save File", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func unavailable(_ title: String, systemImage: String, description: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            if project.isLocal {
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                    Button("Open in Default App") { NSWorkspace.shared.open(fileURL) }
                }
            }
        }
    }

    private func save() {
        guard project.isLocal else { return }
        Task {
            do {
                try await loader.save(fileURL, in: project)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func loadGutter() async {
        guard case .text = loader.phase,
              case .gutter(let staged, let unstaged) = try? await project.git(.gutterDiff(file: fileURL), in: project.root) else {
            gutterDiff = .empty
            return
        }
        gutterDiff = GutterDiffParser.merge(
            unstaged: GutterDiffParser.parse(unstaged, stage: .unstaged),
            staged: GutterDiffParser.parse(staged, stage: .staged)
        )
    }
}

/// Reloads the gutter for a newly loaded file and whenever the project's Git status changes.
private struct GutterID: Equatable {
    let url: URL?
    let repositories: [GitRepositoryStatus]?
}
