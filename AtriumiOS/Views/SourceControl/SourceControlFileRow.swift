import SwiftUI

/// One file entry under a Staged/Changes section. Tapping the row navigates
/// to the diff screen; swipe actions offer stage/unstage/discard.
struct SourceControlFileRow: View {
    @Environment(CompanionClient.self) private var client
    let workspaceId: UUID
    let file: WireGitFile
    /// "staged" or "unstaged".
    let stage: String
    /// Routed up to the screen so the discard alert can drive a single
    /// confirmation. Nil for staged rows where discard isn't offered.
    let onDiscardConfirm: (([WireGitFile]) -> Void)?

    private var isStaged: Bool { stage == "staged" }

    var body: some View {
        NavigationLink(value: Route.fileDiff(
            workspaceId: workspaceId,
            path: file.path,
            stage: stage,
            name: file.name
        )) {
            Label {
                Text(file.name)
                    .lineLimit(1)
            
                if file.path != file.name {
                    Text(parentPath)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
            } icon: {
                statusBadge
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if isStaged {
                Button {
                    client.gitUnstage(workspaceId: workspaceId, files: [file])
                } label: {
                    Label("Unstage", systemImage: "tray.and.arrow.up")
                }
                .tint(.orange)
            } else {
                Button {
                    client.gitStage(workspaceId: workspaceId, files: [file])
                } label: {
                    Label("Stage", systemImage: "tray.and.arrow.down")
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isStaged, let onDiscardConfirm {
                Button(role: .confirm) {
                    onDiscardConfirm([file])
                } label: {
                    Label("Discard", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    private var parentPath: String {
        let components = file.path.split(separator: "/")
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/")
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(badgeLetter)
            .font(.caption2.bold())
            .frame(width: 25, height: 25)
            .foregroundStyle(.white)
            .background(badgeColor, in: .rect(cornerRadius: 4))
    }

    private var badgeLetter: String {
        switch file.status {
        case "added": "A"
        case "modified": "M"
        case "deleted": "D"
        case "renamed": "R"
        case "copied": "C"
        case "untracked": "U"
        case "typeChanged": "T"
        case "conflicted": "!"
        default: "?"
        }
    }

    private var badgeColor: Color {
        switch file.status {
        case "added", "untracked": .green
        case "modified", "typeChanged": .blue
        case "deleted": .red
        case "renamed", "copied": .purple
        case "conflicted": .orange
        default: .gray
        }
    }
}
