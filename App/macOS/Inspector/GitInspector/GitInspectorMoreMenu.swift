import AppKit
import AtriumProtocol
import SwiftUI

/// The Git tab's other actions, beside the commit message: branches,
/// stashes, syncing, pull requests and the commit log. The branch itself is
/// switched at the inspector's foot.
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
                state.stashMessage = ""
                state.showStashAlert = true
            } label: {
                Label("Stash All Changes", systemImage: "tray.and.arrow.down")
            }
            .disabled(snapshot?.isDirty != true)

            Button {
                state.applyLatestStash()
            } label: {
                Label("Apply Latest Stash", systemImage: "tray.and.arrow.up")
            }

            Button {
                state.showStashListSheet = true
            } label: {
                Label("Stashes…", systemImage: "tray.full")
            }
            .disabled(snapshot == nil)

            Divider()

            Button {
                state.showSyncWithBranchSheet = true
            } label: {
                Label("Sync with Branch", systemImage: "arrow.triangle.merge")
            }
            .disabled((snapshot?.localBranches.count ?? 0) < 2)

            Button {
                state.syncWithRemote()
            } label: {
                Label("Sync with Remote", systemImage: "arrow.2.squarepath")
            }
            .disabled(snapshot?.hasTrackingBranch != true)

            Button {
                openPullRequestPage()
            } label: {
                Label("Create Pull Request", systemImage: "arrow.triangle.pull")
            }
            .disabled(snapshot?.branchName == nil || snapshot?.hasTrackingBranch != true)

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

    private func openPullRequestPage() {
        guard let snapshot, let branch = snapshot.branchName else { return }
        Task {
            guard let remoteURLString = await state.model.remoteURL(snapshot),
                  let url = pullRequestWebURL(remoteURL: remoteURLString, branch: branch) else {
                state.model.errorMessage = "Could not determine pull request URL from remote."
                return
            }
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Pull Request URL

private func pullRequestWebURL(remoteURL: String, branch: String) -> URL? {
    // Normalize remote URL to https base
    var base = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if base.hasPrefix("git@") {
        // git@github.com:owner/repo.git → https://github.com/owner/repo
        let address = base.dropFirst(4)
        guard let colon = address.firstIndex(of: ":") else { return nil }
        base = "https://\(address[..<colon])/\(address[address.index(after: colon)...])"
    }
    if base.hasSuffix(".git") {
        base = String(base.dropLast(4))
    }

    guard let parsed = URL(string: base), let host = parsed.host() else { return nil }
    let pathComponents = parsed.pathComponents.filter { $0 != "/" }
    guard pathComponents.count >= 2 else { return nil }
    let owner = pathComponents[0]
    let repo = pathComponents[1]
    let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch

    if host.contains("github") {
        return URL(string: "https://\(host)/\(owner)/\(repo)/pull/new/\(encodedBranch)")
    } else if host.contains("gitlab") {
        return URL(string: "https://\(host)/\(owner)/\(repo)/-/merge_requests/new?merge_request[source_branch]=\(encodedBranch)")
    } else if host.contains("bitbucket") {
        return URL(string: "https://\(host)/\(owner)/\(repo)/pull-requests/new?source=\(encodedBranch)")
    }
    return nil
}

struct SyncWithBranchSheet: View {
    @Bindable var state: GitInspectorState
    @State private var selectedBranch: String?

    private var branches: [String] {
        guard let snapshot = state.currentSnapshot else { return [] }
        return snapshot.localBranches.filter { $0 != snapshot.branchName }
    }

    var body: some View {
        NavigationStack {
            List(branches, id: \.self, selection: $selectedBranch) { branch in
                Text(branch)
            }
            .navigationTitle("Sync with Branch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        state.showSyncWithBranchSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sync") {
                        if let branch = selectedBranch {
                            state.showSyncWithBranchSheet = false
                            state.syncWithBranch(branch)
                        }
                    }
                    .disabled(selectedBranch == nil)
                }
            }
        }
        .frame(width: 280, height: 320)
    }
}

