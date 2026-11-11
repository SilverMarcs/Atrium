import AtriumClient
import AtriumProtocol
import SwiftUI

/// One folder of a project on its host, loaded on its own and kept current
/// while shown. Folders open as screens of their own; files open a preview.
/// Without a folder it shows what the project's scope does, titled and picked
/// as Source Control is.
struct FilesScreen: View {
    let host: HostClient
    let workspaceID: UUID
    var folder: String?
    @AppStorage("showHiddenFiles") private var showsHiddenFiles = false
    @State private var search = FileNameSearch()

    private var scope: ProjectScope { host.scope(for: workspaceID) }
    private var shownFolder: String { folder ?? scope.filesRoot.filePath }
    private var topic: HostTopic { .directory(workspaceID: workspaceID, path: shownFolder) }
    private var workspace: WorkspaceRef { WorkspaceRef(hostID: host.id, workspaceID: workspaceID) }
    private var entries: [FileEntry]? {
        if search.isActive {
            return search.paths?.filter { path in
                showsHiddenFiles || !path.split(separator: "/").contains { $0.hasPrefix(".") }
            }.map { path in
                FileEntry(
                    name: URL(filePath: path).lastPathComponent,
                    path: URL(filePath: shownFolder, directoryHint: .isDirectory).appending(path: path).filePath,
                    isDirectory: false
                )
            }
        }
        return host.directories[topic]?.filter { showsHiddenFiles || !$0.isHidden }
    }

    var body: some View {
        List {
            ForEach(entries ?? []) { entry in
                FileBrowserRow(
                    workspace: workspace, entry: entry,
                    searchRoot: search.isActive ? shownFolder : nil
                )
            }
            if search.isActive, search.isTruncated {
                Text("Showing the first matches only. Refine your search to see more.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .contentMargins(.top, 10)
        .overlay {
            if search.isActive, let error = search.error {
                ContentUnavailableView("Couldn’t Search", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if entries == nil {
                ProgressView()
                    .controlSize(.large)
            } else if search.isActive, entries?.isEmpty == true {
                ContentUnavailableView.search(text: search.submittedText)
            } else if entries?.isEmpty == true {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        .projectScopeTitle(
            host: host, workspaceID: workspaceID, placeholder: "Files",
            title: folder.map { URL(filePath: $0).lastPathComponent }
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsHiddenFiles.toggle()
                } label: {
                    // Tinted as the task list's filter is while it's on.
                    Image(systemName: "doc")
                        .foregroundStyle(showsHiddenFiles ? .accent : .primary)
                }
                .accessibilityLabel("Hidden Files")
                .accessibilityValue(showsHiddenFiles ? "Shown" : "Hidden")
            }
        }
        .searchable(text: $search.text, prompt: "Find Files")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .onSubmit(of: .search) {
            search.submit(in: shownFolder, host: host, workspaceID: workspaceID)
        }
        .onChange(of: shownFolder) {
            if search.isActive { search.submit(in: shownFolder, host: host, workspaceID: workspaceID) }
        }
        .task(id: topic) {
            await host.follow(topic)
        }
    }
}
