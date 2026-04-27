import SwiftUI
import ACPModel

struct PlanView: View {
    let entries: [PlanEntry]
    var onClear: (() -> Void)? = nil
    @State private var isExpanded = false

    private var currentEntry: PlanEntry? {
        entries.first(where: { $0.status == .inProgress })
            ?? entries.first(where: { $0.status == .pending })
    }

    private var completedCount: Int {
        entries.filter { $0.status == .completed }.count
    }

    var body: some View {
        VStack(alignment: .leading) {
            // Collapsed header — always visible
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    if let current = currentEntry {
                        Image(systemName: current.status.systemImage)
                            .foregroundStyle(current.status.color)
                            .font(.caption)
                        Text(current.content)
                            .font(.callout)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("Plan complete")
                            .font(.callout)
                    }

                    Spacer()

                    Text("\(completedCount)/\(entries.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded entries
            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.status.systemImage)
                                .foregroundStyle(entry.status.color)
                                .font(.caption)
                                .frame(width: 14)

                            Text(entry.content)
                                .font(.callout)
                                .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                                .strikethrough(entry.status == .cancelled)
                                .lineLimit(2)

                            Spacer()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if let onClear {
                Button(role: .destructive) {
                    onClear()
                } label: {
                    Label("Clear Plan", systemImage: "trash")
                }
            }
        }
    }
}

extension PlanEntryStatus {
    var systemImage: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted.circle"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        case .cancelled: return .secondary
        }
    }
}
