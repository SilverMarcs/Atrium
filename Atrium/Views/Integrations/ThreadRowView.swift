import SwiftUI

struct ThreadRowView: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    @Environment(WorkspaceStore.self) private var workspaces
    let thread: AgentThread

    var body: some View {
        TaskRowContent(
            title: thread.title,
            projectName: thread.projectName,
            provider: thread.provider,
            status: thread.status,
            hasUnreadResult: thread.hasUnreadResult,
            isSettled: integrations.settledThreadIDs.contains(thread.id),
            snoozedUntil: integrations.snoozedUntil[thread.id]
        ) {
            ThreadWorkspaceIcon(workspace: workspaces.workspace(for: thread))
        }
    }
}
