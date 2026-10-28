import SwiftUI

/// Starts a new task: tapped, in a project and with an agent chosen in a
/// sheet; held, straight away in a project picked from its menu.
struct NewTaskButton: View {
    @Environment(HostDirectory.self) private var hosts
    let action: () -> Void

    private var connectedHosts: [HostClient] { hosts.visibleHosts.filter(\.isConnected) }

    var body: some View {
        Menu {
            ForEach(connectedHosts) { host in
                Section(hosts.showsHostNames ? host.name : "") {
                    ForEach(host.tasks?.workspaces ?? []) { workspace in
                        Button {
                            hosts.openDraft(in: WorkspaceRef(hostID: host.id, workspaceID: workspace.id))
                        } label: {
                            Label {
                                Text(workspace.name)
                                Text(workspace.directory)
                            } icon: {
                                // Menus draw images only, so a custom icon shows as a folder.
                                workspace.projectIcon.map { Image($0) } ?? Image(systemName: "folder")
                            }
                        }
                        .disabled(host.defaultProvider == nil)
                    }
                }
            }
        } label: {
            Label("New Task", systemImage: "square.and.pencil")
        } primaryAction: {
            action()
        }
        .disabled(connectedHosts.isEmpty)
    }
}
