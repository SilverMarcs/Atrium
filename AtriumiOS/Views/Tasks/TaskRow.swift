import SwiftUI

struct TaskRow: View {
    @Environment(CompanionClient.self) private var client
    let task: WireTask

    var body: some View {
        TaskRowContent(
            title: task.title,
            projectName: task.projectName,
            provider: task.provider,
            status: task.status,
            hasUnreadResult: task.hasUnreadResult,
            isSettled: task.isSettled,
            snoozedUntil: task.isSettled ? nil : task.snoozedUntil
        ) {
            WorkspaceIconView(workspace: client.workspace(task.workspaceID), size: 13, relativeTo: .subheadline)
        }
    }
}
