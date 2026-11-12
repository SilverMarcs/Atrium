import AtriumClient
import SwiftUI

/// The sidebar's toolbar control, in place of the system sidebar toggle:
/// clicking it shows or hides the sidebar, and its menu picks the host whose
/// tasks are listed, when there are several, and opens projects.
struct SidebarMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        // A toolbar menu with a primary action keeps the items it was first
        // built with, so the host picker's checkmark stayed where it was when
        // the window opened. A new identity rebuilds them. Wrapping the menu
        // in a stack would keep the toolbar item, but its rebuilt control
        // then missed the window's inactive styling.
        SidebarMenuControl()
            .id(SidebarMenuContent(app.hosts))
    }
}

private struct SidebarMenuControl: View {
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

/// What the sidebar menu's items show.
private struct SidebarMenuContent: Hashable {
    struct Host: Hashable {
        let id: String
        let name: String
        let isConnected: Bool
    }

    let filter: String?
    let hosts: [Host]

    init(_ directory: HostDirectory) {
        filter = directory.filter
        hosts = directory.hosts.map { Host(id: $0.id, name: $0.name, isConnected: $0.isConnected) }
    }
}
