import AtriumClient
import AtriumProtocol
import SwiftUI

struct FileDiffScreen: View {
    let host: HostClient
    let workspaceID: UUID
    let file: GitChangedFile
    let repository: URL
    let isStaged: Bool
    @State private var hunks: [DiffHunk]?
    @State private var message: String?

    var body: some View {
        Group {
            if let hunks, !hunks.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(hunks) { DiffHunkView(hunk: $0) }
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
            hunks = presentation?.hunks ?? []
            message = presentation?.message
        } catch {
            message = error.localizedDescription
        }
    }
}
