import AtriumClient
import AtriumProtocol
import SwiftUI

/// Picks the project's repository when it has several, at the foot of Source
/// Control, Files and Search alike. Files and Search show the one picked on
/// its own when it's inside the project folder. There, a project folder that
/// only holds repositories comes first, showing all of it.
struct InspectorRepositoryPicker: View {
    let project: Project
    /// Whether the whole project folder is a choice, for Files and Search.
    var includesProjectFolder = false

    var body: some View {
        let scope = project.scope
        let repositories = scope.repositories ?? []
        let submodules = repositories.filter { repository in
            repositories.contains {
                $0.mainRepositoryURL != repository.mainRepositoryURL && $0.mainRepositoryURL.contains(repository.mainRepositoryURL)
            }
        }
        let mainRepositories = repositories.filter { !submodules.contains($0) }

        let includesProjectFolder = includesProjectFolder && scope.offersProjectFolder

        Picker(selection: Binding(
            get: { includesProjectFolder && scope.showsProjectFolder ? nil : scope.status?.mainRepositoryURL },
            set: { scope.selectedRepository = $0 }
        )) {
            if includesProjectFolder {
                Label(project.workspace?.name ?? "Project", systemImage: "folder")
                    .tag(URL?.none)

                Divider()
            }

            ForEach(mainRepositories, id: \.mainRepositoryURL) { repository in
                RepositoryLabel(repository: repository)
                    .tag(Optional(repository.mainRepositoryURL))
            }

            if !submodules.isEmpty {
                Section("Submodules") {
                    ForEach(submodules, id: \.mainRepositoryURL) { repository in
                        RepositoryLabel(repository: repository)
                            .tag(Optional(repository.mainRepositoryURL))
                    }
                }
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .controlSize(.large)
        .buttonSizing(.flexible)
    }
}

/// A repository by name, with its branch when it's shown through a linked worktree.
private struct RepositoryLabel: View {
    let repository: GitRepositoryStatus

    var body: some View {
        Label {
            if repository.isLinkedWorktree {
                Text("\(repository.name) (\(repository.branchName ?? "detached"))")
            } else {
                Text(repository.name)
            }
        } icon: {
            Image(systemName: repository.isLinkedWorktree ? "arrow.triangle.branch" : "arrow.right.arrow.left")
        }
        .lineLimit(1)
    }
}
