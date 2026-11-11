import AtriumClient
import AtriumProtocol
import SwiftUI
import UniformTypeIdentifiers

/// Waits for the default draft's host, project and agent to become available.
struct NewChatUnavailableView: View {
    let showDraft: (TaskRef) -> Void
    @Environment(HostDirectory.self) private var hosts
    @State private var showingFolderImporter = false

    /// This Mac's host while it has no projects, so its first can be added here.
    private var hostWithoutProjects: HostClient? {
        hosts.hosts.first { $0.isLocal && $0.isConnected && $0.tasks?.workspaces.isEmpty == true }
    }

    var body: some View {
        Group {
            if !hosts.hasLoadedTasks || hosts.canStartNewChat {
                ProgressView()
            } else if let host = hostWithoutProjects {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder")
                } description: {
                    Text("Add a folder to start a chat in it.")
                } actions: {
                    Button("Add Folder…", systemImage: "folder.badge.plus") { showingFolderImporter = true }
                }
                // The new chat opens in it once the host lists it.
                .fileImporter(isPresented: $showingFolderImporter, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result { host.send(.addWorkspace(path: url.path(percentEncoded: false))) }
                }
            } else {
                ContentUnavailableView(
                    "New Chat Unavailable",
                    systemImage: "square.and.pencil",
                    description: Text("Connect to a host with a project and an installed agent to start a chat.")
                )
            }
        }
        .task(id: hosts.canStartNewChat) {
            if let ref = hosts.prepareNewChat() { showDraft(ref) }
        }
    }
}
