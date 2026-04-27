import SwiftUI
import ACPModel

struct SlashCommandMenu: View {
    let commands: [AvailableCommand]
    let onSelect: (AvailableCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands, id: \.name) { cmd in
                    Button {
                        onSelect(cmd)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("/\(cmd.name)")
                                .font(.system(.body, design: .monospaced))
                            if !cmd.description.isEmpty {
                                Text(cmd.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 320, height: 240)
    }
}
