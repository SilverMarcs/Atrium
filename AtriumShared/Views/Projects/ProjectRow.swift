import SwiftUI

/// A project's icon, name and folder.
struct ProjectRow: View {
    let workspace: WireWorkspace
    let host: HostClient

    var body: some View {
        HStack {
            WorkspaceIcon(workspace, on: host)
            VStack(alignment: .leading) {
                Text(workspace.name)
                Text(workspace.directory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
        }
    }
}
