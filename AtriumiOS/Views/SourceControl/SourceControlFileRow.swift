import SwiftUI

/// A changed file: opens its diff, swipes to stage, unstage or discard.
struct SourceControlFileRow: View {
    @Environment(CompanionClient.self) private var client
    let workspaceID: UUID
    let file: WireGitFile
    let isStaged: Bool
    /// The screen confirms discards; staged rows can't be discarded.
    let onDiscard: (() -> Void)?

    var body: some View {
        NavigationLink(value: Route.fileDiff(workspaceID: workspaceID, file: file, isStaged: isStaged)) {
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
                    client.send(.git(workspaceID: workspaceID, action: .unstage(paths: [file.path])))
                }
                .tint(.orange)
            } else {
                Button("Stage", systemImage: "tray.and.arrow.down") {
                    client.send(.git(workspaceID: workspaceID, action: .stage(paths: [file.path])))
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
        let directory = (file.path as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }
}
