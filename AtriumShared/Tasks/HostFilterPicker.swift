import SwiftUI

/// Narrows task lists to one host, or shows every host's. It never changes
/// which hosts are connected.
struct HostFilterPicker: View {
    @Bindable var hosts: HostDirectory

    var body: some View {
        Picker("Host", selection: $hosts.filter) {
            Label("All Hosts", systemImage: "square.stack.3d.up").tag(String?.none)
            ForEach(hosts.hosts) { host in
                Label(host.name, systemImage: host.isConnected ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                    .tag(Optional(host.id))
            }
        }
    }
}
