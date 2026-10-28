import SwiftUI

/// Finds lines in a project's files on its host, up to its caps.
struct SearchScreen: View {
    let host: HostClient
    let workspaceID: UUID
    @State private var query = ""
    @State private var results: [FileSearchResult]?
    @State private var isTruncated = false
    @State private var isSearching = false
    @State private var error: String?

    private var workspace: WorkspaceRef { WorkspaceRef(hostID: host.id, workspaceID: workspaceID) }

    var body: some View {
        List {
            if isTruncated {
                Text("Showing the first matches only. Search for something more specific to see the rest.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(results ?? []) { result in
                Section {
                    ForEach(result.matches) { match in
                        NavigationLink(value: Route.file(workspace, path: result.path, line: match.lineNumber)) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(match.lineNumber, format: .number.grouping(.never))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                Text(match.line.trimmingCharacters(in: .whitespaces))
                                    .font(.footnote.monospaced())
                                    .lineLimit(2)
                            }
                        }
                    }
                } header: {
                    Text(result.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .overlay {
            if isSearching {
                ProgressView()
                    .controlSize(.large)
            } else if let error {
                ContentUnavailableView("Couldn’t Search", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if results?.isEmpty == true {
                ContentUnavailableView.search(text: query)
            } else if results == nil {
                ContentUnavailableView("Search in Files", systemImage: "magnifyingglass", description: Text("Find text in \(host.workspace(workspaceID)?.name ?? "this project")’s files."))
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Text to find")
        .onSubmit(of: .search) {
            Task { await search() }
        }
        .navigationTitle("Search")
        .toolbarTitleDisplayMode(.inline)
    }

    private func search() async {
        guard !query.isEmpty, let root = host.workspace(workspaceID)?.path else { return }
        isSearching = true
        error = nil
        defer { isSearching = false }
        do {
            guard case .matches(let results, let isTruncated) = try await host.files(.search(root: root, query: query), in: workspaceID) else {
                throw HostClientError.unexpectedReply
            }
            self.results = results
            self.isTruncated = isTruncated
        } catch {
            self.error = error.localizedDescription
        }
    }
}
