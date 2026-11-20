import AtriumClient
import AtriumProtocol
import SwiftUI

/// The checkout the inspector shows, at the foot of every tab: its branch,
/// after its repository's name when the project holds several. Its menu
/// switches the branch or worktree. With several repositories, each is a
/// submenu of its own branches, so one pick shows that repository on the
/// branch picked; the ones the task on screen changed files in come first.
/// Files and Search show the repository picked on its own when it's inside
/// the project folder. There, a project folder that only holds repositories
/// comes first, showing all of it.
struct InspectorScopeFooter: View {
    let project: Project
    /// Whether the whole project folder is a choice, for Files and Search.
    var includesProjectFolder = false

    var body: some View {
        let scope = project.scope
        if let repositories = scope.repositories, let status = scope.status {
            let showsProjectFolder = includesProjectFolder && scope.showsProjectFolder
            HStack {
                Menu {
                    if repositories.count > 1 {
                        RepositoryMenus(
                            project: project,
                            repositories: repositories,
                            selected: showsProjectFolder ? nil : status.mainRepositoryURL,
                            includesProjectFolder: includesProjectFolder && scope.offersProjectFolder
                        )
                    } else {
                        BranchItems(project: project, repository: status)
                    }
                } label: {
                    if showsProjectFolder {
                        Label(project.workspace?.name ?? "Project", systemImage: "folder")
                    } else if repositories.count > 1 {
                        Label { RepositoryTitle(repository: status) } icon: { Image(systemName: "arrow.triangle.branch") }
                    } else {
                        Label(status.shownBranch, systemImage: "arrow.triangle.branch")
                    }
                }
                .controlSize(.large)
                .buttonSizing(.flexible)

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

/// Each repository as a submenu of its branches: submodules, the rest, the
/// project folder when that's a choice, then the ones changed in the task on
/// screen last, nearest the footer the menu opens up from.
private struct RepositoryMenus: View {
    let project: Project
    let repositories: [GitRepositoryStatus]
    /// The repository shown, or nil for the project folder.
    let selected: URL?
    let includesProjectFolder: Bool

    var body: some View {
        let scope = project.scope
        let changed = scope.changedRepositories
        let submodules = repositories.filter { repository in
            !scope.isChanged(repository) && repositories.contains {
                $0.mainRepositoryURL != repository.mainRepositoryURL && $0.mainRepositoryURL.contains(repository.mainRepositoryURL)
            }
        }
        let mainRepositories = repositories.filter { !scope.isChanged($0) && !submodules.contains($0) }

        if !submodules.isEmpty {
            Section("Submodules") {
                ForEach(submodules, id: \.mainRepositoryURL) { repository in
                    RepositoryMenu(project: project, repository: repository, isSelected: repository.mainRepositoryURL == selected)
                }
            }
        }

        ForEach(mainRepositories, id: \.mainRepositoryURL) { repository in
            RepositoryMenu(project: project, repository: repository, isSelected: repository.mainRepositoryURL == selected)
        }

        if includesProjectFolder {
            if !mainRepositories.isEmpty || !submodules.isEmpty {
                Divider()
            }

            Toggle(isOn: Binding(get: { selected == nil }, set: { _ in scope.selectedRepository = nil })) {
                Label(project.workspace?.name ?? "Project", systemImage: "folder")
            }
        }

        if !changed.isEmpty {
            if includesProjectFolder || !mainRepositories.isEmpty || !submodules.isEmpty {
                Divider()
            }

            Section("Changed in This Task") {
                ForEach(changed, id: \.mainRepositoryURL) { repository in
                    RepositoryMenu(project: project, repository: repository, isSelected: repository.mainRepositoryURL == selected)
                }
            }
        }
    }
}

/// A repository and the branch it shows, opening to its branches.
private struct RepositoryMenu: View {
    let project: Project
    let repository: GitRepositoryStatus
    let isSelected: Bool

    var body: some View {
        Menu {
            BranchItems(project: project, repository: repository)
        } label: {
            if isSelected {
                Label { RepositoryTitle(repository: repository) } icon: { Image(systemName: "checkmark") }
            } else {
                RepositoryTitle(repository: repository)
            }
        }
    }
}

/// A repository's name, then the branch it shows in secondary text, which a
/// menu item keeps as its title's color.
private struct RepositoryTitle: View {
    let repository: GitRepositoryStatus

    var body: some View {
        Text("\(repository.name) · \(Text(repository.shownBranch).foregroundStyle(.secondary))")
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
        project.scope.selectedRepository = repository.mainRepositoryURL
        Task { await project.git.model.selectBranch(branch, in: repository) }
    }

    private func select(worktree: GitWorktreeInfo) {
        project.scope.selectedRepository = repository.mainRepositoryURL
        guard !worktree.isCurrent else { return }
        project.git.activateWorktree(worktree, in: repository)
    }
}

private extension GitRepositoryStatus {
    var shownBranch: String { branchName ?? "Detached HEAD" }
}
