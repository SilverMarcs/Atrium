import SwiftUI

struct MacRow: View {
    let mac: PairedMac
    let isCurrent: Bool
    let onRename: () -> Void

    var body: some View {
        Button(action: onRename) {
            HStack {
                Label {
                    Text(mac.displayName)
                        .foregroundStyle(.primary)
                    if mac.customName != nil {
                        Text(mac.hostName)
                    }
                } icon: {
                    Image(systemName: "macbook")
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
