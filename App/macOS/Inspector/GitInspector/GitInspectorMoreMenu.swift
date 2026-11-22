import AtriumProtocol
import SwiftUI

/// The Git tab's other actions, beside the commit message: branches, the
/// commit log and reviewing the branch's changes. The branch itself is switched at the inspector's foot.
struct GitInspectorMoreMenu: View {
    @Bindable var state: GitInspectorState
    @Environment(\.openWindow) private var openWindow

    private var snapshot: GitRepositoryStatus? { state.currentSnapshot }

    var body: some View {
        Menu {
            Button {
                state.newBranchName = ""
                state.showNewBranchSheet = true
            } label: {
                Label("New Branch", systemImage: "plus")
            }

            Button {
                state.branchListSnapshot = snapshot
            } label: {
                Label("Branches…", systemImage: "list.bullet.indent")
            }
            .disabled(snapshot == nil)

            Divider()

            Button {
                state.showCommitLogSheet = true
            } label: {
                Label("Commit Log", systemImage: "clock.arrow.circlepath")
            }
            .disabled(snapshot == nil)

            Button {
                guard let snapshot else { return }
                openWindow(value: GitDiffWindowItem(
                    project: state.project.id,
                    repositoryRootURL: snapshot.repositoryRootURL,
                    subject: .review(head: nil, name: snapshot.branchName ?? "HEAD")
                ))
            } label: {
                Label("Review Changes", systemImage: "text.magnifyingglass")
            }
            .disabled(snapshot == nil)

            Divider()

            Button {
                state.fetch()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            // As tall as the Commit button's arrow, so the two buttons match;
            // the ellipsis alone makes a flat one.
            ZStack {
                Image(systemName: "arrow.up").hidden()
                Image(systemName: "ellipsis")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .help("More")
    }
}
