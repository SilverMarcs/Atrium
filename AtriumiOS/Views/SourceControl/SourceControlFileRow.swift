import AtriumProtocol
import SwiftUI

/// A changed file: opens its diff, swipes to stage, unstage or discard.
struct SourceControlFileRow: View {
    let source: SourceControl
    let file: GitChangedFile
    let isStaged: Bool
    /// The screen confirms discards; staged rows can't be discarded.
    let onDiscard: (() -> Void)?

    var body: some View {
        NavigationLink(value: Route.fileDiff(source.workspace, file: file, repository: source.status?.repositoryRootURL ?? file.fileURL, isStaged: isStaged)) {
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
                    source.send(.unstage(paths: [file.repositoryRelativePath]))
                }
                .tint(.orange)
            } else {
                Button("Stage", systemImage: "tray.and.arrow.down") {
                    source.send(.stage(paths: [file.repositoryRelativePath]))
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            if let onDiscard {
                Button("Discard", systemImage: "arrow.uturn.backward", action: onDiscard)
                    .tint(.red)
            }
        }
    }

    private var parent: String? {
        let directory = (file.repositoryRelativePath as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }
}
