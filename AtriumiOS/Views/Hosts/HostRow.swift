import SwiftUI

struct HostRow: View {
    let host: HostClient
    let onRename: () -> Void

    var body: some View {
        Button(action: onRename) {
            Label {
                Text(host.name)
                    .foregroundStyle(.primary)
                Text(status)
            } icon: {
                Image(systemName: "desktopcomputer")
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var status: String {
        if host.needsAppUpdate { return "Update Atrium to use this host" }
        switch host.state {
        case .connected: return host.route == .localNetwork ? "Connected on this network" : "Connected through the relay"
        case .connecting: return "Connecting…"
        case .offline(let reason): return reason
        }
    }
}
