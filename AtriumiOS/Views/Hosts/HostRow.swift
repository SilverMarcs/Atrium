import SwiftUI

struct HostRow: View {
    let host: PairedHost
    let isCurrent: Bool
    let onRename: () -> Void

    var body: some View {
        Button(action: onRename) {
            HStack {
                Label {
                    Text(host.displayName)
                        .foregroundStyle(.primary)
                    if host.customName != nil {
                        Text(host.hostName)
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
