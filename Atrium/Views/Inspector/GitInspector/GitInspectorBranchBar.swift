import AppKit
import SwiftUI

struct GitInspectorBranchBar: View {
    let directoryURL: URL
    @Bindable var state: GitInspectorState

    private var snapshot: GitRepositoryStatusSnapshot? { state.currentSnapshot }

    var body: some View {
        HStack(spacing: 4) {
            branchPicker
            Spacer()
            if state.model.isBusy {
                ProgressView()
                    .controlSize(.mini)
            }
            menuButton
        }
    }

    private var branchPicker: some View {
        Menu {
            if let snapshot {
                // One picker across both sections so the checkmark can land in either.
                // The section contents are a pure function of the repo — they don't
                // change with which branch/worktree is currently in view.
                Picker(selection: contextSelection(snapshot)) {
                    Section("Branches") {
                        ForEach(branchNames(in: snapshot), id: \.self) { branch in
                            Text(branch).tag(GitContextItem.branch(branch))
                        }
                    }
                    let worktrees = linkedWorktrees(in: snapshot)
                    if !worktrees.isEmpty {
                        Section("Worktrees") {
                            ForEach(worktrees) { worktree in
                                Text(worktree.branch ?? "(detached)")
                                    .tag(GitContextItem.worktree(worktree.path))
                            }
                        }
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label {
                Text(snapshot?.branchName ?? "No Branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "arrow.triangle.branch")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
    }

    private var menuButton: some View {
        Menu {
            Button {
                state.newBranchName = ""
                state.showNewBranchSheet = true
            } label: {
                Label("New Branch", systemImage: "plus")
            }

            Button {
                state.showBranchListSheet = true
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
                state.applyLatestStash(directoryURL: directoryURL)
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
                state.syncWithRemote(directoryURL: directoryURL)
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
                state.fetch(directoryURL: directoryURL)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Branches listed under "Branches": all local branches except those checked out
    /// in a linked worktree (each of those is represented by its worktree entry). Pure
    /// function of the branch/worktree lists — identical no matter which is in view.
    private func branchNames(in snapshot: GitRepositoryStatusSnapshot) -> [String] {
        let linked = linkedWorktrees(in: snapshot)
        return snapshot.localBranches.filter { branch in
            !linked.contains { $0.branch == branch }
        }
    }

    /// The linked worktrees (everything that isn't the primary or a bare entry). Does
    /// not depend on the current selection, so the list stays stable across switches.
    private func linkedWorktrees(in snapshot: GitRepositoryStatusSnapshot) -> [GitWorktreeInfo] {
        snapshot.worktrees.filter { !$0.isMain && !$0.isBare }
    }

    /// Where the checkmark sits and what a selection does. Only this — not the list —
    /// reflects the current context: a linked worktree checkmarks in Worktrees, any
    /// other branch (including the main worktree's) checkmarks in Branches.
    private func contextSelection(_ snapshot: GitRepositoryStatusSnapshot) -> Binding<GitContextItem> {
        Binding(
            get: {
                if let current = snapshot.worktrees.first(where: { $0.isCurrent }), !current.isMain {
                    return .worktree(current.path)
                }
                return .branch(snapshot.branchName ?? "")
            },
            set: { item in
                switch item {
                case .branch(let branch):
                    guard branch != snapshot.branchName else { return }
                    if let worktree = snapshot.worktrees.first(where: { $0.branch == branch }) {
                        state.activateWorktree(worktree, in: snapshot)
                    } else {
                        state.switchBranch(to: branch, directoryURL: directoryURL, snapshot: snapshot)
                    }
                case .worktree(let path):
                    guard let worktree = snapshot.worktrees.first(where: { $0.path == path }),
                          !worktree.isCurrent else { return }
                    state.activateWorktree(worktree, in: snapshot)
                }
            }
        )
    }

    private func openPullRequestPage() {
        guard let snapshot, let branch = snapshot.branchName else { return }
        Task {
            guard let remoteURLString = await state.model.remoteURL(snapshot: snapshot),
                  let url = pullRequestWebURL(remoteURL: remoteURLString, branch: branch) else {
                state.model.errorMessage = "Could not determine pull request URL from remote."
                return
            }
            NSWorkspace.shared.open(url)
        }
    }
}

/// A selectable entry in the branch picker: a plain branch, or a linked worktree
/// (keyed by path so detached worktrees, which have no branch, still work).
private enum GitContextItem: Hashable {
    case branch(String)
    case worktree(URL)
}

// MARK: - Pull Request URL

private func pullRequestWebURL(remoteURL: String, branch: String) -> URL? {
    // Normalize remote URL to https base
    var base = remoteURL
    if base.hasPrefix("git@") {
        // git@github.com:owner/repo.git → https://github.com/owner/repo
        base = base
            .replacingOccurrences(of: "git@", with: "https://")
            .replacingOccurrences(of: ":", with: "/", range: base.range(of: ":", range: base.index(base.startIndex, offsetBy: 4)..<base.endIndex))
    }
    if base.hasSuffix(".git") {
        base = String(base.dropLast(4))
    }
    base = base.trimmingCharacters(in: .whitespacesAndNewlines)

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
    let directoryURL: URL
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
                            state.syncWithBranch(branch, directoryURL: directoryURL)
                        }
                    }
                    .disabled(selectedBranch == nil)
                }
            }
        }
        .frame(width: 280, height: 320)
    }
}

