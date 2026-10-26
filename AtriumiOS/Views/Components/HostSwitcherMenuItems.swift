import SwiftUI

/// Switches between paired hosts, with a way into managing them. Meant for a
/// toolbar title menu.
struct HostSwitcherMenuItems: View {
    @Environment(CompanionClient.self) private var client
    let onEdit: () -> Void

    var body: some View {
        Picker("Host", selection: Binding(
            get: { client.currentHost?.id },
            set: { id in
                if let host = client.pairedHosts.first(where: { $0.id == id }) { client.select(host) }
            }
        )) {
            ForEach(client.pairedHosts) { host in
                Label(host.displayName, systemImage: "macbook")
                    .tag(Optional(host.id))
            }
        }

        Divider()

        Button("Edit Hosts…", systemImage: "pencil", action: onEdit)
    }
}
