import SwiftUI

/// Switches between paired Macs, with a way into managing them. Meant for a
/// toolbar title menu.
struct MacSwitcherMenuItems: View {
    @Environment(CompanionClient.self) private var client
    let onEdit: () -> Void

    var body: some View {
        Picker("Mac", selection: Binding(
            get: { client.currentMac?.id },
            set: { id in
                if let mac = client.pairedMacs.first(where: { $0.id == id }) { client.select(mac) }
            }
        )) {
            ForEach(client.pairedMacs) { mac in
                Label(mac.displayName, systemImage: "macbook")
                    .tag(Optional(mac.id))
            }
        }

        Divider()

        Button("Edit Macs…", systemImage: "pencil", action: onEdit)
    }
}
