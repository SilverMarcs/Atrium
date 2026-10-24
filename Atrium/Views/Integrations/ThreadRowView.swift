import SwiftUI

struct ThreadRowView: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    @Environment(WorkspaceStore.self) private var workspaces
    let thread: AgentThread

    private var workspace: Workspace? {
        workspaces.workspace(for: thread)
    }

    var body: some View {
        let badge: Text? = if thread.status == .waiting {
            Text("●").foregroundStyle(.orange)
        } else if thread.hasUnreadResult && thread.status != .processing {
            Text("●").foregroundStyle(.blue)
        } else {
            nil
        }

        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(thread.title)
                    .lineLimit(1)
                    // .font(.headline)
                    // .fontWeight(.semibold)

                Spacer()

                if !integrations.settledThreadIDs.contains(thread.id) {
                    if thread.status == .processing {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Processing")
                    } else if let badge {
                        badge
                            .font(.caption2)
                            .accessibilityLabel(thread.status == .waiting ? "Needs input" : "Unread result")
                    }
                }
            }
            HStack(spacing: 5) {
                ThreadWorkspaceIcon(workspace: workspace)
                Text(thread.projectName)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let snoozedUntil = integrations.snoozedUntil[thread.id] {
                    Text(snoozedUntil, format: .dateTime.weekday().hour().minute())
                        .lineLimit(1)
                        .help("Snoozed until \(snoozedUntil.formatted(date: .abbreviated, time: .shortened))")
                }

                Image(thread.provider.symbolName)
                    .foregroundStyle(thread.provider.color)
                    .accessibilityLabel(thread.provider.name)
                    .help(thread.provider.name)
            }
            .font(.subheadline) //
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 1)
    }
}
