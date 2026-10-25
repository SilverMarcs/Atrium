import SwiftUI

struct HostRow: View {
    let host: DiscoveredHost
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Label {
                    Text(host.name)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "macbook")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
    }
}
