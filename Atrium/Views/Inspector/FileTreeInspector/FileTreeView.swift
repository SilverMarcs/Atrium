import SwiftUI

struct FileTreeView: View {
    let directoryURL: URL
    @Bindable var state: FileTreeInspectorState

    @Environment(EditorPanel.self) private var editorPanel
    @AppStorage("showHiddenFiles") private var showHiddenFiles = false
    @State private var pendingTrashURL: URL?

    var body: some View {
        List(selection: $state.selectedID) {
            ForEach(state.model.displayItems) { item in
                FileNodeView(item: item)
            }
        }
        .environment(state)
        .environment(\.fileTreeAction, handleAction)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            if let id = selectedIDs.first,
               let item = state.model.findItem(id: id) {
                FileTreeContextMenu(item: item, onAction: handleAction)
            }
        } primaryAction: { selectedIDs in
            for id in selectedIDs {
                if let item = state.model.findItem(id: id), !item.isDirectory {
                    editorPanel.openFile(item.url)
                }
            }
        }
        .contextMenu {
            Button { handleAction(.newFile(directoryURL)) } label: {
                Label("New File", systemImage: "doc.badge.plus")
            }
            Button { handleAction(.newFolder(directoryURL)) } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Divider()
            Toggle("Show Hidden Files", isOn: $showHiddenFiles)
        }
        .safeAreaBar(edge: .bottom) {
            SearchBar(
                text: $state.model.searchText,
                placeholder: "Search for Files",
                focusTrigger: state.searchFocusTrigger,
                isLoading: state.model.isSearching,
                onSubmit: submitSearch
            ) {
                Button(action: toggleChangedFilter) {
                    Image(systemName: state.model.showChangedOnly ? "plusminus.circle.fill" : "plusminus.circle")
                        .foregroundStyle(state.model.showChangedOnly ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Show only git-changed files")
            }
            .padding(11)
        }
        .task(id: directoryURL) {
            state.model.showHiddenFiles = showHiddenFiles
            state.model.load(directoryURL: directoryURL)
            await state.model.refreshGit(directoryURL: directoryURL)
        }
        .watchFileSystem(at: directoryURL) {
            state.model.load(directoryURL: directoryURL)
        }
        .gitPolling(id: directoryURL) {
            await state.model.refreshGit(directoryURL: directoryURL)
        }
        .alert(
            "Move to Trash?",
            isPresented: Binding(
                get: { pendingTrashURL != nil },
                set: { if !$0 { pendingTrashURL = nil } }
            ),
            presenting: pendingTrashURL
        ) { url in
            Button("Move to Trash", role: .destructive) {
                state.model.moveToTrash(url: url, directoryURL: directoryURL)
            }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text("Are you sure you want to move \u{201C}\(url.lastPathComponent)\u{201D} to the Trash?")
        }
        .onChange(of: state.model.searchText) {
            if state.model.searchText.isEmpty && !state.model.submittedSearchText.isEmpty {
                state.model.clearSearch()
            }
        }
        .onChange(of: state.model.submittedSearchText) { oldValue, newValue in
            if !newValue.isEmpty && oldValue.isEmpty {
                if state.savedExpandedIDs == nil {
                    state.savedExpandedIDs = state.expandedIDs
                }
            } else if newValue.isEmpty && !oldValue.isEmpty && !state.model.showChangedOnly {
                if let saved = state.savedExpandedIDs {
                    state.expandedIDs = saved
                    state.savedExpandedIDs = nil
                }
            }
        }
        .onChange(of: state.model.filteredItems) {
            if state.model.hasActiveFilter {
                expandAllFolders(in: state.model.displayItems)
            }
        }
        .onChange(of: showHiddenFiles) {
            state.model.showHiddenFiles = showHiddenFiles
            state.model.load(directoryURL: directoryURL)
        }
        .onChange(of: state.selectedID) { _, newID in
            guard let id = newID,
                  let item = state.model.findItem(id: id),
                  !item.isDirectory
            else { return }
            editorPanel.openFile(item.url)
        }
    }

    private func toggleChangedFilter() {
        if !state.model.showChangedOnly {
            if state.savedExpandedIDs == nil {
                state.savedExpandedIDs = state.expandedIDs
            }
            expandAllFolders(in: state.model.displayItems)
        } else if state.model.submittedSearchText.isEmpty, let saved = state.savedExpandedIDs {
            state.expandedIDs = saved
            state.savedExpandedIDs = nil
        }
        state.model.toggleChangedOnly()
    }

    private func submitSearch() {
        guard !state.model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.model.submitSearch()
    }

    private func expandAllFolders(in items: [FileItem]) {
        for item in items {
            if item.children != nil {
                state.expandedIDs.insert(item.id)
                if let children = item.children {
                    expandAllFolders(in: children)
                }
            }
        }
    }

    // MARK: - Actions

    private func handleAction(_ action: FileTreeAction) {
        switch action {
        case .openFile(let url):
            editorPanel.openFile(url)

        case .revealInFinder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])

        case .rename(let item):
            state.renamingID = item.id

        case .commitRename(let item, let newName):
            state.renamingID = nil
            if let newURL = state.model.rename(url: item.url, to: newName, directoryURL: directoryURL) {
                state.selectedID = newURL.path
            }

        case .moveToTrash(let url):
            pendingTrashURL = url

        case .duplicate(let url):
            state.model.duplicate(url: url, directoryURL: directoryURL)

        case .newFile(let parentURL):
            let fileURL = state.model.createNewFile(in: parentURL, directoryURL: directoryURL)
            state.expandedIDs.insert(parentURL.path)
            state.selectedID = fileURL.path
            state.renamingID = fileURL.path

        case .newFolder(let parentURL):
            let folderURL = state.model.createNewFolder(in: parentURL, directoryURL: directoryURL)
            state.expandedIDs.insert(parentURL.path)
            state.selectedID = folderURL.path
            state.renamingID = folderURL.path
        }
    }
}
