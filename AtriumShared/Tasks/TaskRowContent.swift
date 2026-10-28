import SwiftUI

/// A task list row, shared by every client: the title and status, then the
/// project and, when several hosts are listed, the host it's on, any snooze
/// time, and the agent, grayed out once its session has ended.
struct TaskRowContent<ProjectIcon: View>: View {
    let title: String
    let projectName: String
    var hostName: String? = nil
    let provider: AgentProvider
    let status: AgentThreadStatus
    let hasUnreadResult: Bool
    let isSettled: Bool
    let snoozedUntil: Date?
    @ViewBuilder let projectIcon: ProjectIcon

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .lineLimit(1)

                Spacer()

                TaskStatusIndicator(status: status, hasUnreadResult: hasUnreadResult, isSettled: isSettled)
                    .controlSize(.mini)
                    .font(.caption2)
            }
            HStack(spacing: 5) {
                projectIcon
                Text(projectName)
                    .lineLimit(1)
                if let hostName {
                    Text(hostName)
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                if let snoozedUntil {
                    Text(snoozedUntil, format: .dateTime.weekday().hour().minute())
                        .lineLimit(1)
                        .help("Snoozed until \(snoozedUntil.formatted(date: .abbreviated, time: .shortened))")
                }

                ProviderIcon(provider: provider, isLive: status.isLive)
                    .help(provider.name)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 1)
    }
}
