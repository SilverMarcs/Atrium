import AtriumClient
import SwiftUI

/// The places a task's project opens: its commands, source control and
/// files, each in the checkout the project's scope shows. Search stays
/// hidden for now.
struct ProjectLinks: View {
    let workspace: WorkspaceRef

    var body: some View {
        NavigationLink(value: Route.commands(workspace)) {
            Label("Commands", systemImage: "terminal")
        }
        NavigationLink(value: Route.sourceControl(workspace)) {
            Label("Source Control", systemImage: "arrow.triangle.branch")
        }
        NavigationLink(value: Route.files(workspace)) {
            Label("Files", systemImage: "folder")
        }
    }
}
