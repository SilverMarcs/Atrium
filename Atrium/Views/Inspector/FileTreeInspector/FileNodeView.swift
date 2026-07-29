import SwiftUI

struct FileNodeView: View {
    let item: FileItem
    @Environment(FileTreeInspectorState.self) private var state
    @Environment(EditorPanel.self) private var editorPanel
    @Environment(\.fileTreeAction) private var onAction

    var body: some View {
        @Bindable var state = state
        if let children = item.children {
            DisclosureGroup(isExpanded: Binding(
                get: { state.expandedIDs.contains(item.id) },
                set: { newValue in
                    if newValue {
                        state.expandedIDs.insert(item.id)
                    } else {
                        state.expandedIDs.remove(item.id)
                    }
                }
            )) {
                ForEach(children) { child in
                    FileNodeView(item: child)
                }
            } label: {
                Button {
                    withAnimation {
                        if state.expandedIDs.contains(item.id) {
                            state.expandedIDs.remove(item.id)
                        } else {
                            state.expandedIDs.insert(item.id)
                        }
                    }
                } label: {
                    FileRowView(item: item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                    .contextMenu { FileTreeContextMenu(item: item, onAction: onAction) }
            }
            .tag(item.id)
            .listRowSeparator(.hidden)
        } else {
            Button {
                if state.selectedID == item.id {
                    editorPanel.openFile(item.url)
                } else {
                    state.selectedID = item.id
                }
            } label: {
                FileRowView(item: item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .tag(item.id)
                .contextMenu { FileTreeContextMenu(item: item, onAction: onAction) }
                .listRowSeparator(.hidden)
        }
    }
}
