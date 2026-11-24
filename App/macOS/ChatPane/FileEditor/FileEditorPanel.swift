import SwiftUI

/// A file from the project's host in the pane beside the chat: editable on
/// this Mac's own host, read-only on any other, and reloaded when it changes
/// there. Unsaved changes are saved when the pane moves on to something else.
struct FileEditorPanel: View {
    let fileURL: URL
    let project: Project
    @State private var loader = FileEditorLoadModel()
    @State private var saveError: String?
    @State private var gutterDiff: GutterDiffResult = .empty
    @State private var showingPreview = false
    @Environment(\.editorFontSize) private var editorFontSize
    @Environment(AppModel.self) private var app

    private var editor: ProjectEditor { project.editor }
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
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem {
                    title
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
                ToolbarItemGroup {
                    actions
                }
            }
            .onChange(of: fileURL, initial: true) { old, url in
                if old != url { saveIfNeeded() }
                showingPreview = false
                saveError = nil
                gutterDiff = .empty
                loader.load(url, in: project)
            }
            .onDisappear { saveIfNeeded() }
            .task(id: fileURL) {
                await project.host.follow(.file(workspaceID: project.workspaceID, path: path))
            }
            .onChange(of: project.host.fileRevisions[.file(workspaceID: project.workspaceID, path: path)]) {
                loader.reloadIfUnchanged(fileURL, in: project)
            }
            .task(id: GutterID(url: loader.loadedURL, repositories: project.repositories)) {
                await loadGutter()
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

    private var title: some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIcon.image(for: fileURL))
                .resizable()
                .frame(width: 16, height: 16)
            Text(fileURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
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
            if loader.hasUnsavedChanges {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        }
        .padding(.horizontal, 4)
        .help(fileURL.relativePath(from: project.root))
    }

    @ViewBuilder
    private var actions: some View {
        if isMarkdownFile, case .text = loader.phase {
            Button(showingPreview ? "Show Editor" : "Show Preview",
                   systemImage: showingPreview ? "chevron.left.forwardslash.chevron.right" : "doc.richtext") {
                showingPreview.toggle()
            }
            .help(showingPreview ? "Show Editor" : "Show Preview")
        }
        // Only this Mac's files have a default app to open them here.
        if project.isLocal {
            Button("Open in Default App", systemImage: "macwindow") { NSWorkspace.shared.open(fileURL) }
                .help("Open in Default App")
        }
        Button("Show in File Tree", systemImage: "folder") {
            project.reveal(fileURL)
            app.showInspector(.files, in: project)
        }
        .keyboardShortcut("j", modifiers: [.command, .shift])
        .help("Show in File Tree")
    }

    @ViewBuilder
    private var content: some View {
        switch loader.phase {
        case .text where loader.loadedURL != fileURL:
            // Still the last file's text, for the frame before this file starts loading.
            Color.clear
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
                    highlightRequest: editor.highlightRequest,
                    scrollToLine: editor.pendingScrollLine,
                    hunkTarget: HunkTarget(project: project, repository: project.checkout(containing: fileURL)),
                    onReloadFromDisk: {
                        await loader.reloadInPlace(fileURL, in: project)
                        await loadGutter()
                    },
                    onSave: save
                )
                // Scrolls on under the toolbar, which insets it.
                .ignoresSafeArea(.container, edges: .top)
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

    /// Saves changes the pane is about to leave behind.
    private func saveIfNeeded() {
        if loader.hasUnsavedChanges { save() }
    }

    /// Saves the text as it is now, to the file it was loaded from.
    private func save() {
        guard project.isLocal, case .text = loader.phase, let url = loader.loadedURL else { return }
        let text = loader.content
        Task {
            do {
                try await loader.save(text, to: url, in: project)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func loadGutter() async {
        guard case .text = loader.phase,
              case .gutter(let staged, let unstaged) = try? await project.git(.gutterDiff(file: fileURL), in: project.checkout(containing: fileURL)) else {
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
