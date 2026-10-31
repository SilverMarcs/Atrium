import AtriumClient
import AtriumProtocol
import SwiftUI

/// Picks the project's repository when it has several, at the foot of Source
/// Control, Files and Search alike. Files and Search show the one picked on
/// its own when it's inside the project folder.
struct InspectorRepositoryPicker: View {
    let project: Project

    var body: some View {
        let scope = project.scope
        let repositories = scope.repositories ?? []
        let submodules = repositories.filter { repository in
            repositories.contains {
                $0.mainRepositoryURL != repository.mainRepositoryURL && $0.mainRepositoryURL.contains(repository.mainRepositoryURL)
            }
        }
        let mainRepositories = repositories.filter { !submodules.contains($0) }

        Picker(selection: Binding(
            get: { scope.status?.mainRepositoryURL },
            set: { scope.selectedRepository = $0 }
        )) {
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
