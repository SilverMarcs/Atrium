import SwiftUI

struct HostRow: View {
    let host: CompanionClient.DiscoveredHost
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "macbook")
                    .foregroundStyle(.secondary)
                Text(host.name)
                    .foregroundStyle(.primary)
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
