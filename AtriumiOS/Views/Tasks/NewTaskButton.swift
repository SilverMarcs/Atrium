import SwiftUI

/// Starts a new task, while connected to the host: tapped, in a project and
/// with an agent chosen in a sheet; held, straight away in a project picked
/// from its menu.
struct NewTaskButton: View {
    @Environment(CompanionClient.self) private var client
    let action: () -> Void
    let openProject: (UUID) -> Void

    var body: some View {
        Menu {
            ForEach(client.tasks?.workspaces ?? []) { workspace in
                Button {
                    openProject(workspace.id)
                } label: {
                    Label {
                        Text(workspace.name)
                        Text(workspace.directory)
                    } icon: {
                        // Menus draw images only, so a custom icon shows as a folder.
                        workspace.projectIcon.map { Image($0) } ?? Image(systemName: "folder")
                    }
                }
                .disabled(client.defaultProvider == nil)
            }
        } label: {
            Label("New Task", systemImage: "square.and.pencil")
        } primaryAction: {
            action()
        }
        .disabled(!client.isConnected)
    }
}
