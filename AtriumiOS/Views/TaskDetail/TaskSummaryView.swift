import SwiftUI

/// What the detail screen shows until it can mirror the task's terminal:
/// the task's state, agent, project and recent activity.
struct TaskSummaryView: View {
    @Environment(CompanionClient.self) private var client
    let task: WireTask

    private var workspace: WireWorkspace? { client.workspace(task.workspaceID) }

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    HStack {
                        Image(systemName: task.status.systemImage)
                        Text(task.status.rawValue)
                    }
                    .foregroundStyle(task.status.color)
                }
                if task.isSettled {
                    LabeledContent("Settled", value: "Yes")
                } else if let snoozedUntil = task.snoozedUntil {
                    LabeledContent("Snoozed Until") {
                        Text(snoozedUntil, format: .dateTime.weekday().hour().minute())
                    }
                }
                if task.hasUnreadResult {
                    LabeledContent("Result", value: "Unread")
                }
                LabeledContent("Updated") {
                    Text(task.updatedAt, format: .relative(presentation: .named))
                }
            }

            Section("Agent") {
                Label {
                    Text(task.provider.name)
                } icon: {
                    ProviderIcon(provider: task.provider, isLive: task.status.isLive)
                }
            }

            Section("Project") {
                Label {
                    Text(workspace?.name ?? task.projectName)
                } icon: {
                    WorkspaceIconView(workspace: workspace)
                }
                LabeledContent("Folder") {
                    Text(task.directory)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
