import SwiftUI

struct WorkspaceRow: View {
    let workspace: WireWorkspace

    var body: some View {
        Label {
            Text(workspace.name)
                .lineLimit(1)
        } icon: {
            WorkspaceIconView(customIconData: workspace.customIconData)
        }
        .badge(connectedCount > 0 ? Text("\(connectedCount)") : nil)
        .badgeProminence(hasAnyNotification ? .increased : .standard)
    }

    private var connectedCount: Int {
        workspace.sessions.filter { $0.isActive && !$0.isArchived }.count
    }

    private var hasAnyNotification: Bool {
        workspace.sessions.contains { $0.hasNotification && !$0.isArchived }
    }
}
