import SwiftUI

struct SearchInspectorView: View {
    let directoryURL: URL
    @Bindable var state: SearchInspectorState

    @Environment(EditorPanel.self) private var editorPanel

    var body: some View {
        List(selection: $state.selectedID) {
            ForEach(state.model.results) { fileResult in
                DisclosureGroup(isExpanded: binding(for: fileResult.id)) {
                    ForEach(fileResult.matches) { match in
                        matchRow(match)
                            .tag(match.id)
                            .padding(.leading, -15)
                    }
                } label: {
                    FileLabel(name: fileResult.fileName, icon: fileResult.fileURL.fileIcon) {
                        if let disambiguator = fileResult.disambiguator {
                            Text(disambiguator)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .tag(fileResult.id)
            }
            .listRowSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        .safeAreaBar(edge: .top) {
            SearchBar(
                text: $state.model.query,
                placeholder: "Search Within Files",
                focusTrigger: state.searchFocusTrigger,
                isLoading: state.model.isSearching,
                onSubmit: {
                    state.model.search(in: directoryURL)
                }
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .padding(.top, 6)
        }
        .onChange(of: state.model.results) {
            state.expandedIDs = Set(state.model.results.map(\.id))
        }
        .onChange(of: state.selectedID) { _, newID in
            guard let id = newID else { return }

            if let fileResult = state.model.results.first(where: { $0.id == id }) {
                editorPanel.openFile(fileResult.fileURL)
                return
            }

            for fileResult in state.model.results {
                if let match = fileResult.matches.first(where: { $0.id == id }) {
                    editorPanel.openFileAndHighlight(
                        match.fileURL,
                        lineNumber: match.lineNumber,
                        columnRange: match.columnRange
                    )
                    return
                }
            }
        }
    }
    private func matchRow(_ match: SearchMatch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(match.lineNumber)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 28, alignment: .trailing)

            Text(match.highlightedContent)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { state.expandedIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    state.expandedIDs.insert(id)
                } else {
                    state.expandedIDs.remove(id)
                }
            }
        )
    }
}
