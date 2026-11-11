import AtriumProtocol
import SwiftUI

/// A changed file: opens its diff, swipes to stage, unstage or discard.
/// Staged files can't be discarded.
struct SourceControlFileRow: View {
    let source: SourceControl
    let status: GitRepositoryStatus
    let file: GitChangedFile
    let isStaged: Bool

    var body: some View {
        NavigationLink(value: Route.fileDiff(source.workspace, file: file, repository: status.repositoryRootURL, isStaged: isStaged)) {
            Label {
                Text(file.name)
                    .lineLimit(1)
                if let parent {
                    Text(parent)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
            } icon: {
                GitChangeBadge(kind: file.kind)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if isStaged {
                Button("Unstage", systemImage: "tray.and.arrow.up") {
                    Task { await source.unstage([file], in: status) }
                }
                .tint(.orange)
            } else {
                Button("Stage", systemImage: "tray.and.arrow.down") {
                    Task { await source.stage([file], in: status) }
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            if !isStaged {
                Button("Discard", systemImage: "arrow.uturn.backward") {
                    source.prompt = .discard([file], status)
                }
                .tint(.red)
            }
        }
    }

    private var parent: String? {
        let directory = (file.repositoryRelativePath as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }
}
