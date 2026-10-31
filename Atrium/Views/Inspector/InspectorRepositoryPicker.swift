import AtriumClient
import AtriumProtocol
import SwiftUI

/// Picks the repository the inspector shows when the project has several, for
/// Source Control and, with the project folder as a choice too, for Files and
/// Search. Either way it's the project's one picked repository.
struct InspectorRepositoryPicker: View {
    let project: Project
    /// Whether the whole project folder is a choice, for Files.
    var includesProjectFolder = false

    var body: some View {
        let scope = project.scope
        let repositories = includesProjectFolder ? scope.nestedRepositories : scope.repositories ?? []
        let submodules = repositories.filter { repository in
            repositories.contains {
                $0.mainRepositoryURL != repository.mainRepositoryURL && $0.mainRepositoryURL.contains(repository.mainRepositoryURL)
            }
        }
        let mainRepositories = repositories.filter { !submodules.contains($0) }

        Picker(selection: Binding(
            get: { includesProjectFolder ? scope.selectedNestedRepository : scope.status?.mainRepositoryURL },
            set: { scope.selectedRepository = $0 }
        )) {
            if includesProjectFolder {
                Label(project.workspace?.name ?? "Project", systemImage: "folder")
                    .tag(URL?.none)
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
