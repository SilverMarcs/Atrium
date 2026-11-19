import AtriumProtocol
import SwiftUI

/// The Git tab's other actions, beside the commit message: branches and the
/// commit log. The branch itself is switched at the inspector's foot.
struct GitInspectorMoreMenu: View {
    @Bindable var state: GitInspectorState

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
