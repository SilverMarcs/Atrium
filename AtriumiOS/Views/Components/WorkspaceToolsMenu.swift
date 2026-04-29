import SwiftUI

/// Plus menu shared between the chat list and the chat detail screen. Both
/// surfaces sit under the same workspace, so commands and source control
/// are reachable from either place.
struct WorkspaceToolsMenu: View {
    let workspaceId: UUID

    var body: some View {
        Menu {
            NavigationLink(value: Route.commands(workspaceId)) {
                Label("Commands", systemImage: "terminal")
            }
            NavigationLink(value: Route.sourceControl(workspaceId)) {
                Label("Source Control", systemImage: "arrow.triangle.branch")
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}
