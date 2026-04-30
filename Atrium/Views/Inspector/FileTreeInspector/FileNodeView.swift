import SwiftUI

struct FileNodeView: View {
    let item: FileItem
    @Environment(FileTreeInspectorState.self) private var state

    var body: some View {
        @Bindable var state = state
        if item.children != nil {
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
                ForEach(item.children!) { child in
                    FileNodeView(item: child)
                }
            } label: {
                FileRowView(item: item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation {
                            if state.expandedIDs.contains(item.id) {
                                state.expandedIDs.remove(item.id)
                            } else {
                                state.expandedIDs.insert(item.id)
                            }
                        }
                    }
                    .contextMenu { FileTreeContextMenu(item: item) }
            }
            .listRowSeparator(.hidden)
        } else {
            FileRowView(item: item)
                .tag(item.id)
                .contextMenu { FileTreeContextMenu(item: item) }
                .listRowSeparator(.hidden)
        }
    }
}
