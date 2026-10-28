import SwiftUI

/// One folder of a project on its host, loaded on its own and kept current
/// while shown. Folders open as screens of their own; files open a preview.
struct FilesScreen: View {
    let host: HostClient
    let workspaceID: UUID
    let folder: String
    @AppStorage("showHiddenFiles") private var showsHiddenFiles = false
    @State private var search = FileNameSearch()

    private var topic: HostTopic { .directory(workspaceID: workspaceID, path: folder) }
    private var workspace: WorkspaceRef { WorkspaceRef(hostID: host.id, workspaceID: workspaceID) }
    private var entries: [FileEntry]? {
        if search.isActive {
            return search.paths?.filter { path in
                showsHiddenFiles || !path.split(separator: "/").contains { $0.hasPrefix(".") }
            }.map { path in
                FileEntry(
                    name: URL(filePath: path).lastPathComponent,
                    path: URL(filePath: folder, directoryHint: .isDirectory).appending(path: path).filePath,
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
                    searchRoot: search.isActive ? folder : nil
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
        .navigationTitle(isRoot ? host.workspace(workspaceID)?.name ?? "Files" : (folder as NSString).lastPathComponent)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(showsHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files", systemImage: "line.3.horizontal.decrease") {
                    showsHiddenFiles.toggle()
                }
                .foregroundStyle(showsHiddenFiles ? .accent : .primary)
                .accessibilityValue(showsHiddenFiles ? "Shown" : "Hidden")
            }
        }
        .searchable(text: $search.text, prompt: "Find Files")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .onSubmit(of: .search) {
            search.submit(in: folder, host: host, workspaceID: workspaceID)
        }
        .task(id: topic) {
            await host.follow(topic)
        }
    }

    private var isRoot: Bool { folder == host.workspace(workspaceID)?.path }
}
