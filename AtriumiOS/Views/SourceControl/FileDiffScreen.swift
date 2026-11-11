import AtriumClient
import AtriumProtocol
import SwiftUI

struct FileDiffScreen: View {
    let host: HostClient
    let workspaceID: UUID
    let file: GitChangedFile
    let repository: URL
    let isStaged: Bool
    @State private var hunks: [(header: String, listing: CodeListing)]?
    @State private var message: String?

    var body: some View {
        Group {
            if let hunks, !hunks.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(hunks, id: \.listing.id) { DiffHunkView(header: $0.header, listing: $0.listing) }
                    }
                    .padding(.vertical, 8)
                }
            } else if let message {
                ContentUnavailableView("No Diff", systemImage: "doc.plaintext", description: Text(message))
            } else if hunks != nil {
                ContentUnavailableView("No Changes", systemImage: "doc.plaintext")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(file.name)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: Route.file(
                    WorkspaceRef(hostID: host.id, workspaceID: workspaceID),
                    path: file.fileURL.path(percentEncoded: false)
                )) {
                    Label("Open File", systemImage: "arrow.up.forward.square")
                }
            }
        }
        .task(id: file) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let reference = GitDiffReference(
            repositoryRootURL: repository,
            fileURL: file.fileURL,
            repositoryRelativePath: file.repositoryRelativePath,
            stage: isStaged ? .staged : .unstaged,
            kind: file.kind
        )
        do {
            guard case .diff(let text, _) = try await host.git(.diff(reference), in: repository, workspace: workspaceID) else {
                throw HostClientError.unexpectedReply
            }
            let presentation = text.isEmpty ? nil : DiffFilePresentation(raw: text)
            hunks = (presentation?.hunks ?? []).map { hunk in
                (hunk.header, CodeListing(lines: CodeLine.lines(of: hunk), fileName: file.name))
            }
            message = presentation?.message
        } catch {
            message = error.localizedDescription
        }
    }
}
