import AtriumProtocol
import SwiftUI

/// Committing and remote operations for the selected repository.
struct SourceControlActionsMenu: View {
    let source: SourceControl
    /// Asks for a message to commit the staged changes with.
    let onCommit: () -> Void

    var body: some View {
        let status = source.status
        Menu {
            Button("Push", systemImage: "arrow.up") { run(source.push) }
                .disabled(status.map { $0.unpushedCommits.isEmpty && $0.hasTrackingBranch } ?? true)
            Button("Pull", systemImage: "arrow.down") { run(source.pull) }
                .disabled(status?.hasTrackingBranch != true)
            Button("Fetch", systemImage: "arrow.clockwise") { run(source.fetch) }

            Divider()

            Button("Commit", systemImage: "checkmark", action: onCommit)
                .disabled(status?.stagedFiles.isEmpty != false)
        } label: {
            Label("Actions", systemImage: "point.topleft.down.curvedto.point.bottomright.up.fill")
        }
        .disabled(status == nil)
    }

    private func run(_ operation: @escaping (GitRepositoryStatus) async -> Void) {
        guard let status = source.status else { return }
        Task { await operation(status) }
    }
}
