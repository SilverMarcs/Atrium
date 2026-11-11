import SwiftUI

struct GitBranchRow: View {
    let name: String
    var subtitle: String?
    let icon: String
    let isCurrent: Bool
    let isMerged: Bool

    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : icon)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            VStack(alignment: .leading) {
                Text(name)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(subtitle)
                }
            }
            Spacer()
            if isMerged {
                Text("Merged")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.background.secondary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
