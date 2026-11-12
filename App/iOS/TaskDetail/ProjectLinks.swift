import AtriumClient
import SwiftUI

/// The places a task's project opens, in the Mac inspector's order: its
/// files, source control, search and commands, each in the checkout the
/// project's scope shows. Search stays hidden for now; it belongs between
/// Source Control and Commands when it returns.
struct ProjectLinks: View {
    let workspace: WorkspaceRef

    var body: some View {
        NavigationLink(value: Route.files(workspace)) {
            Label("Files", systemImage: "folder")
        }
        NavigationLink(value: Route.sourceControl(workspace)) {
            Label("Source Control", systemImage: "arrow.triangle.branch")
        }
        NavigationLink(value: Route.commands(workspace)) {
            Label("Commands", systemImage: "terminal")
        }
    }
}
