import SwiftUI

struct FileRowView: View {
    let item: FileItem
    @Environment(FileTreeInspectorState.self) private var state
    @Environment(\.fileTreeAction) private var onAction

    @State private var editingName = ""
    @FocusState private var isFocused: Bool

    private var isRenaming: Bool { state.renamingID == item.id }

    var body: some View {
        HStack(spacing: 4) {
            Label {
                if isRenaming {
                    TextField("", text: $editingName)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { onAction(.commitRename(item, item.name)) }
                        .lineLimit(1)
                } else {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } icon: {
                Image(nsImage: item.icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }

            Spacer()

            if let status = item.gitStatus {
                Text(status.statusSymbol)
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(item.isHidden ? 0.5 : 1)
        .task(id: isRenaming) {
            guard isRenaming else { return }
            editingName = item.name
            try? await Task.sleep(for: .milliseconds(50))
            isFocused = true
        }
    }

    private func commitRename() {
        let name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        onAction(.commitRename(item, name.isEmpty ? item.name : name))
    }
}
