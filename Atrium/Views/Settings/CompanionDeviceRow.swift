import SwiftUI

struct CompanionDeviceRow: View {
    let device: CompanionPairedDevice
    let isConnected: Bool
    let onRemove: () -> Void

    var body: some View {
        LabeledContent {
            Button("Remove", role: .destructive, action: onRemove)
        } label: {
            Label {
                Text(device.name)
                if isConnected {
                    Text("Connected")
                } else if let lastConnectedAt = device.lastConnectedAt {
                    Text("Last connected \(lastConnectedAt, format: .relative(presentation: .named))")
                }
            } icon: {
                Image(systemName: "iphone")
            }
        }
    }
}
