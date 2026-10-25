import SwiftUI

/// Repositories in the project, grouped under the branch each has checked out.
struct RepositoryPicker: View {
    let status: WireGitStatus
    let onSelect: (String) -> Void

    var body: some View {
        Picker("Repository", selection: Binding(
            get: { status.selectedRepositoryPath ?? "" },
            set: { path in
                guard !path.isEmpty, path != status.selectedRepositoryPath else { return }
                onSelect(path)
            }
        )) {
            ForEach(groups, id: \.branch) { group in
                Section(group.branch) {
                    ForEach(group.repositories) { repository in
                        Text(repository.name).tag(repository.path)
                    }
                }
            }
        }
    }

    /// Branches keep first-seen order so the menu stays stable across refreshes.
    private var groups: [(branch: String, repositories: [WireGitRepository])] {
        var order: [String] = []
        var buckets: [String: [WireGitRepository]] = [:]
        for repository in status.repositories {
            let branch = repository.branchName ?? "—"
            if buckets[branch] == nil { order.append(branch) }
            buckets[branch, default: []].append(repository)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
