import AtriumClient
import SwiftUI

/// The places a task's project opens: its commands, source control and files.
struct ProjectLinks: View {
    let workspace: WorkspaceRef
    /// The project folder on its host, where browsing files starts.
    let root: String

    var body: some View {
        NavigationLink(value: Route.commands(workspace)) {
            Label("Commands", systemImage: "terminal")
        }
        NavigationLink(value: Route.sourceControl(workspace)) {
            Label("Source Control", systemImage: "arrow.triangle.branch")
        }
        NavigationLink(value: Route.files(workspace, folder: root)) {
            Label("Files", systemImage: "folder")
        }
    }
}
