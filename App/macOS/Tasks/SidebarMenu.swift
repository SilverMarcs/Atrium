import AtriumClient
import SwiftUI

/// The sidebar's toolbar control, in place of the system sidebar toggle:
/// clicking it shows or hides the sidebar, and its menu picks the host whose
/// tasks are listed, when there are several, and opens projects.
struct SidebarMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            // With one host there's nothing to narrow the list to.
            if app.hosts.hosts.count > 1 {
                HostFilterPicker(hosts: app.hosts)
                    .pickerStyle(.inline)
                    .labelsHidden()
                Divider()
            }
            Button("Projects", systemImage: "folder") { app.showingProjects = true }
                .disabled(!app.hosts.hosts.contains(where: \.isConnected))
        } label: {
            Label("Sidebar", systemImage: "sidebar.leading")
        } primaryAction: {
            withAnimation {
                app.sidebarVisibility = app.sidebarVisibility == .detailOnly ? .automatic : .detailOnly
            }
        }
        .help("Show or hide the sidebar")
    }
}
