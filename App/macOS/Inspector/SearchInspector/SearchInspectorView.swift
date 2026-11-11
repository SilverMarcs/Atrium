import AtriumClient
import AtriumProtocol
import SwiftUI

/// Find in files across the project, on its host.
struct SearchInspectorView: View {
    let project: Project

    var body: some View {
        @Bindable var state = project.search
        List(selection: $state.selectedID) {
            if state.isTruncated {
                Text("Showing the first matches only. Search for something more specific to see the rest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Flat rows rather than disclosure groups: SwiftUI's outline list
            // traps when a group's contents change as it collapses, and results
            // are replaced wholesale on every search.
            ForEach(state.results) { fileResult in
                let isExpanded = state.expandedIDs.contains(fileResult.id)
                Button {
                    withAnimation { binding(for: fileResult.id).wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        DisclosureChevron(isExpanded: isExpanded)
                        FileLabel(name: fileResult.name, icon: FileIcon.image(for: URL(filePath: fileResult.path))) {
                            if let folder = Self.folder(of: fileResult) {
                                Text(folder)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .listRowSeparator(.hidden)

                if isExpanded {
                    ForEach(fileResult.matches) { match in
                        let id = matchID(match, in: fileResult)
                        matchRow(match)
                            .padding(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                            .onTapGesture {
                                if state.selectedID == id {
                                    open(match, in: fileResult)
                                } else {
                                    state.selectedID = id
                                }
                            }
                            .tag(id)
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaBar(edge: .top) {
            SearchBar(
                text: $state.query,
                placeholder: "Search Within Files",
                focusTrigger: state.searchFocusTrigger,
                isLoading: state.isSearching,
                onSubmit: state.search
            )
            .padding(.horizontal, 10)
            .padding(.top, 9)
        }
        .safeAreaBar(edge: .bottom) {
            if (project.scope.repositories?.count ?? 0) > 1 {
                InspectorRepositoryPicker(project: project, includesProjectFolder: true)
                    .padding()
            }
        }
        // Searching again below the folder now shown, so no result points into another checkout.
        .onChange(of: project.filesRoot) { state.search() }
        .onChange(of: state.results) {
            state.expandedIDs = Set(state.results.map(\.id))
        }
        .onChange(of: InspectorSelection(state, state.selectedID)) { old, new in
            guard old.owner == new.owner, let id = new.selection else { return }
            for fileResult in state.results {
                if let match = fileResult.matches.first(where: { matchID($0, in: fileResult) == id }) {
                    open(match, in: fileResult)
                    return
                }
            }
        }
    }

    private func open(_ match: FileSearchMatch, in result: FileSearchResult) {
        project.editor.openFileAndHighlight(URL(filePath: result.path), lineNumber: match.lineNumber, columnRange: match.columns)
    }

    private func matchID(_ match: FileSearchMatch, in result: FileSearchResult) -> String {
        "\(result.relativePath):\(match.id)"
    }

    /// The folder a result is in, so files sharing a name can be told apart.
    private static func folder(of result: FileSearchResult) -> String? {
        let folder = (result.relativePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : (folder as NSString).lastPathComponent
    }

    private func matchRow(_ match: FileSearchMatch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(match.lineNumber)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 28, alignment: .trailing)

            Text(SearchInspectorModel.highlighted(match))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        let state = project.search
        return Binding(
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
