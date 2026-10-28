import SwiftUI

/// One folder of a project on its host, loaded on its own and kept current
/// while shown. Folders open as screens of their own; files open a preview.
struct FilesScreen: View {
    let host: HostClient
    let workspaceID: UUID
    let folder: String
    @AppStorage("showHiddenFiles") private var showsHiddenFiles = false

    private var topic: HostTopic { .directory(workspaceID: workspaceID, path: folder) }
    private var workspace: WorkspaceRef { WorkspaceRef(hostID: host.id, workspaceID: workspaceID) }
    private var entries: [FileEntry]? {
        host.directories[topic]?.filter { showsHiddenFiles || !$0.isHidden }
    }

    var body: some View {
        List(entries ?? []) { entry in
            NavigationLink(value: entry.isDirectory ? Route.files(workspace, folder: entry.path) : Route.file(workspace, path: entry.path)) {
                Label {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                }
                .opacity(entry.isHidden ? 0.5 : 1)
            }
        }
        .contentMargins(.top, 10)
        .overlay {
            if entries == nil {
                ProgressView()
                    .controlSize(.large)
            } else if entries?.isEmpty == true {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        .navigationTitle(isRoot ? host.workspace(workspaceID)?.name ?? "Files" : (folder as NSString).lastPathComponent)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Options", systemImage: "ellipsis") {
                    Toggle("Show Hidden Files", systemImage: "eye", isOn: $showsHiddenFiles)
                    if isRoot {
                        NavigationLink(value: Route.search(workspace)) {
                            Label("Search in Files", systemImage: "magnifyingglass")
                        }
                    }
                }
            }
        }
        .task(id: topic) {
            await host.follow(topic)
        }
    }

    private var isRoot: Bool { folder == host.workspace(workspaceID)?.path }
}
