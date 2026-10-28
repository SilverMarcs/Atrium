import SwiftUI

/// A paired host's name over how it's connected.
struct HostLabel: View {
    let host: HostClient

    var body: some View {
        Label {
            Text(host.name)
                .foregroundStyle(.primary)
            Text(status)
        } icon: {
            Image(systemName: "macbook")
        }
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
