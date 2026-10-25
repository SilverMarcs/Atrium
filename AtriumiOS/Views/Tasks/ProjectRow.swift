import SwiftUI

struct ProjectRow: View {
    let workspace: WireWorkspace
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Label {
                    Text(workspace.name)
                    Text(workspace.directory)
                        .truncationMode(.middle)
                } icon: {
                    WorkspaceIconView(workspace: workspace)
                }
                .lineLimit(1)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
