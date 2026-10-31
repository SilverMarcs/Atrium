import AtriumClient
import AtriumProtocol
import SwiftUI

/// A task in a list that can span hosts, naming its host when it needs to.
struct TaskRow: View {
    let item: HostTask
    var showsHost = false

    var body: some View {
        let task = item.task
        // Work it delegated shows on the task listed for it, as in its chat:
        // waiting for an answer, or still running after the task's turn ends.
        let needsInput = task.status != .waiting && item.host.tasks?.delegatedWorkNeedsInput(task.id) == true
        TaskRowContent(
            title: task.title,
            projectName: task.projectName,
            hostName: showsHost ? item.host.name : nil,
            provider: task.provider,
            status: needsInput ? .waiting : item.progressStatus,
            hasUnreadResult: task.hasUnreadResult,
            isSettled: task.isSettled,
            snoozedUntil: task.isSettled ? nil : task.snoozedUntil
        ) {
            WorkspaceIcon(item.workspace, on: item.host, size: 13, relativeTo: .subheadline)
        }
    }
}
