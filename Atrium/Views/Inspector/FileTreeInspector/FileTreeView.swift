import AtriumClient
import AtriumProtocol
import SwiftUI

/// A project's files on its host, folders loading as they're expanded.
struct FileTreeView: View {
    let project: Project
    @AppStorage("showHiddenFiles") private var showHiddenFiles = false
    @State private var pendingTrash: FileEntry?
    @State private var revealScrollTask: Task<Void, Never>?

    private var model: FileTreeModel { project.fileTree }
    private var rootPath: String { project.filesRoot.filePath }

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            List(selection: $model.selectedID) {
                if let nodes = model.filteredNodes {
                    if model.isTruncated {
                        Text("Showing the first \(HostProtocol.maxFoundFiles) matches.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(nodes) { FilteredFileRow(node: $0, project: project) }
                } else {
                    FolderRows(path: rootPath, project: project, showsHidden: showHiddenFiles)
                }
            }
            .scrollContentBackground(.hidden)
            .environment(\.fileTreeAction, handle)
            .contextMenu(forSelectionType: String.self) { _ in
            } primaryAction: { ids in
                for id in ids where !isFolder(id) {
                    project.editor.openFile(URL(filePath: id))
                }
            }
            .contextMenu {
                if project.isLocal {
                    Button("New File", systemImage: "doc.badge.plus") { handle(.create(in: rootPath, isFolder: false)) }
                    Button("New Folder", systemImage: "folder.badge.plus") { handle(.create(in: rootPath, isFolder: true)) }
                    Divider()
                }
                Toggle("Show Hidden Files", isOn: $showHiddenFiles)
            }
            .safeAreaBar(edge: .top) {
                SearchBar(
                    text: $model.searchText,
                    placeholder: "Search for Files",
                    focusTrigger: model.searchFocusTrigger,
                    isLoading: model.isSearching,
                    onSubmit: submitSearch
                ) {
                    Button(action: toggleChangedFilter) {
                        Image(systemName: model.showChangedOnly ? "plusminus.circle.fill" : "plusminus.circle")
                            .foregroundStyle(model.showChangedOnly ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show only changed files")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .padding(.top, 6)
            }
            .safeAreaBar(edge: .bottom) {
                if (project.scope.repositories?.count ?? 0) > 1 {
                    InspectorRepositoryPicker(project: project)
                        .padding()
                }
            }
            .onChange(of: model.shownFolders, initial: true) { _, folders in
                model.follow(folders)
            }
            .onDisappear {
                revealScrollTask?.cancel()
                model.follow([])
            }
            .onChange(of: model.pendingRevealID, initial: true) { _, id in
                if let id { scrollToFile(id, using: proxy) }
            }
            .onChange(of: rootPath) {
                if !model.submittedSearchText.isEmpty { model.find() }
            }
            .onChange(of: model.searchText) {
                if model.searchText.isEmpty && !model.submittedSearchText.isEmpty { model.clearSearch() }
            }
            .onChange(of: model.hasActiveFilter) { _, isFiltered in
                if isFiltered {
                    model.savedExpandedIDs = model.savedExpandedIDs ?? model.expandedIDs
                } else if let saved = model.savedExpandedIDs {
                    model.expandedIDs = saved
                    model.savedExpandedIDs = nil
                }
            }
            .onChange(of: model.filteredNodes) { _, nodes in
                if let nodes { expandAll(nodes) }
            }
            .onChange(of: InspectorSelection(model, model.selectedID)) { old, new in
                guard old.owner == new.owner, let id = new.selection, !isFolder(id) else { return }
                if model.pendingRevealID == id {
                    model.pendingRevealID = nil
                    return
                }
                project.editor.openFile(URL(filePath: id))
            }
            .alert("Move to Trash?", isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }), presenting: pendingTrash) { entry in
                Button("Move to Trash", role: .confirm) { Task { await model.trash(entry.path) } }
                Button("Cancel", role: .cancel) {}
            } message: { entry in
                Text("Are you sure you want to move “\(entry.name)” to the Trash?")
            }
        }
    }

    private func isFolder(_ path: String) -> Bool {
        model.expandedIDs.contains(path)
            || model.entries(in: (path as NSString).deletingLastPathComponent)?.first { $0.path == path }?.isDirectory == true
            || model.entries(in: path) != nil
    }

    private func scrollToFile(_ id: String, using proxy: ScrollViewProxy) {
        revealScrollTask?.cancel()
        var targets = [id]
        var parent = (id as NSString).deletingLastPathComponent
        while parent.hasPrefix(rootPath + "/") {
            targets.append(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        revealScrollTask = Task {
            // Collapsed folders create their rows only once expanded and loaded.
            for target in targets.reversed() {
                guard (try? await Task.sleep(for: .milliseconds(30))) != nil else { return }
                proxy.scrollTo(target, anchor: .center)
            }
            model.selectedID = id
        }
    }

    private func toggleChangedFilter() {
        model.showChangedOnly.toggle()
    }

    private func submitSearch() {
        guard !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.submitSearch()
    }

    private func expandAll(_ nodes: [FileNode]) {
        for node in nodes {
            guard let children = node.children else { continue }
            model.expandedIDs.insert(node.id)
            expandAll(children)
        }
    }

    private func handle(_ action: FileTreeAction) {
        switch action {
        case .open(let entry):
            project.editor.openFile(entry.url)
        case .revealInFinder(let entry):
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        case .rename(let entry):
            model.renamingID = entry.id
        case .commitRename(let entry, let name):
            model.renamingID = nil
            guard name != entry.name else { return }
            Task { await model.rename(entry.path, to: name) }
        case .trash(let entry):
            pendingTrash = entry
        case .duplicate(let entry):
            Task { await model.duplicate(entry.path) }
        case .create(let folder, let isFolder):
            Task { await model.create(in: folder, isFolder: isFolder) }
        }
    }
}

enum FileTreeAction {
    case open(FileEntry)
    case revealInFinder(FileEntry)
    case rename(FileEntry)
    case commitRename(FileEntry, String)
    case trash(FileEntry)
    case duplicate(FileEntry)
    case create(in: String, isFolder: Bool)
}

/// One folder's entries, each folder in it expanding into its own.
private struct FolderRows: View {
    let path: String
    let project: Project
    let showsHidden: Bool

    var body: some View {
        @Bindable var model = project.fileTree
        let entries = (model.entries(in: path) ?? []).filter { showsHidden || !$0.isHidden }
        ForEach(entries) { entry in
            if entry.isDirectory {
                DisclosureGroup(isExpanded: $model[isExpanded: entry.id]) {
                    if project.fileTree.expandedIDs.contains(entry.id) {
                        FolderRows(path: entry.path, project: project, showsHidden: showsHidden)
                    }
                } label: {
                    FolderLabel(entry: entry, project: project)
                }
                .id(entry.id)
                .tag(entry.id)
                .listRowSeparator(.hidden)
            } else {
                FileRow(entry: entry, project: project)
                    .id(entry.id)
                    .tag(entry.id)
                    .listRowSeparator(.hidden)
            }
        }
    }
}

/// A row of the tree a filter shows, with every folder in it already known.
private struct FilteredFileRow: View {
    let node: FileNode
    let project: Project

    var body: some View {
        @Bindable var model = project.fileTree
        if let children = node.children {
            DisclosureGroup(isExpanded: $model[isExpanded: node.id]) {
                ForEach(children) { FilteredFileRow(node: $0, project: project) }
            } label: {
                FolderLabel(entry: node.entry, project: project)
            }
            .id(node.id)
            .tag(node.id)
            .listRowSeparator(.hidden)
        } else {
            FileRow(entry: node.entry, project: project)
                .id(node.id)
                .tag(node.id)
                .listRowSeparator(.hidden)
        }
    }
}

/// A folder's row, which expands or collapses it when clicked.
private struct FolderLabel: View {
    let entry: FileEntry
    let project: Project

    var body: some View {
        @Bindable var model = project.fileTree
        Button {
            withAnimation { model[isExpanded: entry.id].toggle() }
        } label: {
            FileRow(entry: entry, project: project)
        }
        .buttonStyle(.plain)
    }
}

private struct FileRow: View {
    let entry: FileEntry
    let project: Project
    @Environment(\.fileTreeAction) private var perform
    @State private var editingName = ""
    @FocusState private var isFocused: Bool

    private var isRenaming: Bool { project.fileTree.renamingID == entry.id }

    var body: some View {
        HStack(spacing: 4) {
            Label {
                if isRenaming {
                    TextField("Name", text: $editingName)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .onSubmit { perform(.commitRename(entry, editingName.isEmpty ? entry.name : editingName)) }
                        .onExitCommand { perform(.commitRename(entry, entry.name)) }
                        .lineLimit(1)
                } else {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } icon: {
                Image(nsImage: FileIcon.image(for: entry.url, isDirectory: entry.isDirectory))
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Spacer()
            if let status = project.fileTree.status(of: entry.path) {
                Text(status.statusSymbol)
                    .font(.caption2)
                    .bold()
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(entry.isHidden ? 0.5 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .contextMenu { FileTreeContextMenu(entry: entry, isLocal: project.isLocal) }
        .task(id: isRenaming) {
            guard isRenaming else { return }
            editingName = entry.name
            try? await Task.sleep(for: .milliseconds(50))
            isFocused = true
        }
    }
}

private struct FileTreeContextMenu: View {
    let entry: FileEntry
    let isLocal: Bool
    @Environment(\.fileTreeAction) private var perform

    private var folder: String { entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent }

    var body: some View {
        if !entry.isDirectory {
            Button("Open File", systemImage: "doc") { perform(.open(entry)) }
        }
        // Files on another host can be read but not changed from here.
        if isLocal {
            Button("Reveal in Finder", systemImage: "folder") { perform(.revealInFinder(entry)) }
            Divider()
            Button("Rename", systemImage: "pencil") { perform(.rename(entry)) }
            Button("Duplicate", systemImage: "doc.on.doc") { perform(.duplicate(entry)) }
            Button("Move to Trash", systemImage: "trash", role: .destructive) { perform(.trash(entry)) }
            Divider()
            Button("New File", systemImage: "doc.badge.plus") { perform(.create(in: folder, isFolder: false)) }
            Button("New Folder", systemImage: "folder.badge.plus") { perform(.create(in: folder, isFolder: true)) }
        }
    }
}
