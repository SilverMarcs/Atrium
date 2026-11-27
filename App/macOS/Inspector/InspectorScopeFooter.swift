import SwiftUI

/// The folder the inspector shows, at the foot of every tab. With one
/// folder, a repository, it's that repository's branch, and its menu
/// switches the branch or worktree. With several, it's the folder's name
/// and its branch, and its menu picks the folder, listing each with its
/// branch under it: a repository as a submenu of its branches, so one pick
/// shows it on the branch picked, or a plain folder. The ones the task on
/// screen changed files in come last, nearest the footer the menu opens up from.
/// A task working in a linked worktree locks the repositories it works in:
/// the menu lists only those, as plain folders without branches, and with
/// just one the footer only names it. The lines a branch committed since it
/// left the default branch sit at its trailing edge.
struct InspectorScopeFooter: View {
    let project: Project

    var body: some View {
        let scope = project.scope
        if scope.repositories != nil, let selected = scope.selected, scope.folders.count > 1 || selected.status != nil {
            let locked = selected.status.flatMap { scope.isLocked($0) ? $0 : nil }
            let hasFolders = scope.pickableFolderCount > 1
            HStack {
                Menu {
                    if hasFolders {
                        FolderMenus(project: project, selected: selected.key)
                    } else if let status = selected.status {
                        BranchItems(project: project, repository: status)
                    }
                } label: {
                    HStack {
                        if hasFolders, let status = selected.status {
                            Label {
                                Text("\(selected.name) · \(Text(status.shownBranch).foregroundStyle(.secondary))")
                            } icon: {
                                Image(systemName: "arrow.triangle.branch")
                            }
                        } else if hasFolders {
                            Label(selected.name, systemImage: "folder")
                        } else if let status = selected.status {
                            Label(status.shownBranch, systemImage: "arrow.triangle.branch")
                        }

                        // What the branch committed since it left the default branch.
                        if let lines = selected.status?.branchLines, !lines.isEmpty {
                            Spacer()
                            LineCounts(added: lines.added, removed: lines.removed)
                                .monospacedDigit()
                                .fixedSize()
                                // Nearer the menu's chevron than its label's own trailing edge.
                                .padding(.trailing, -10)
                        }
                    }
                    .lineLimit(1)
                }
                .controlSize(.large)
                .buttonSizing(.flexible)
                .disabled(locked != nil && !hasFolders)
                .help(locked?.repositoryRootURL.filePath ?? "")

                // Switching a branch here can take a moment, as can the Git tab's work.
                if project.git.model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding()
        }
    }
}

/// Each folder, a repository as a submenu of its branches, in the order
/// `ProjectScope.pickableFolders` gives.
private struct FolderMenus: View {
    let project: Project
    /// The `ProjectFolder.key` of the folder shown.
    let selected: URL

    var body: some View {
        let (unchanged, changed) = project.scope.pickableFolders

        ForEach(unchanged) { folder in
            FolderMenu(project: project, folder: folder, isSelected: folder.key == selected)
        }

        if !changed.isEmpty {
            if !unchanged.isEmpty {
                Divider()
            }

            Section("Changed in This Task") {
                ForEach(changed) { folder in
                    FolderMenu(project: project, folder: folder, isSelected: folder.key == selected)
                }
            }
        }
    }
}

/// A repository and the branch it shows, opening to its branches, or a plain
/// folder: also a repository a task's worktree locks, under its branch.
private struct FolderMenu: View {
    let project: Project
    let folder: ProjectFolder
    let isSelected: Bool

    // Loose texts become the menu item's title and subtitle; a stack would
    // leave only the first.
    var body: some View {
        if let repository = folder.status, !project.scope.isLocked(repository) {
            Menu {
                BranchItems(project: project, repository: repository)
            } label: {
                if isSelected { Image(systemName: "checkmark") }
                Text(folder.name)
                Text(repository.shownBranch)
            }
        } else {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in project.scope.selectedFolder = folder.key })) {
                Text(folder.name)
                if let repository = folder.status { Text(repository.shownBranch) }
            }
        }
    }
}

/// A repository's branches and linked worktrees, checked where it shows.
/// Picking one shows the repository there, so picking the branch it's
/// already on just shows the repository.
private struct BranchItems: View {
    let project: Project
    let repository: GitRepositoryStatus

    var body: some View {
        let worktrees = repository.worktrees.filter { !$0.isMain && !$0.isBare }
        // A branch checked out in a linked worktree is listed as that worktree.
        let branches = repository.localBranches.filter { branch in !worktrees.contains { $0.branch == branch } }
        let current = repository.worktrees.first { $0.isCurrent && !$0.isMain }

        Section("Branches") {
            ForEach(branches, id: \.self) { branch in
                Toggle(branch, isOn: Binding(
                    get: { current == nil && repository.branchName == branch },
                    set: { _ in select(branch: branch) }
                ))
            }
        }
        if !worktrees.isEmpty {
            Section("Worktrees") {
                ForEach(worktrees, id: \.path) { worktree in
                    Toggle(worktree.branch ?? "(detached)", isOn: Binding(
                        get: { current?.path == worktree.path },
                        set: { _ in select(worktree: worktree) }
                    ))
                }
            }
        }
    }

    private func select(branch: String) {
        project.scope.selectedFolder = repository.mainRepositoryURL
        Task { await project.git.model.selectBranch(branch, in: repository) }
    }

    private func select(worktree: GitWorktreeInfo) {
        project.scope.selectedFolder = repository.mainRepositoryURL
        guard !worktree.isCurrent else { return }
        project.git.activateWorktree(worktree, in: repository)
    }
}

private extension GitRepositoryStatus {
    var shownBranch: String { branchName ?? "Detached HEAD" }
}
