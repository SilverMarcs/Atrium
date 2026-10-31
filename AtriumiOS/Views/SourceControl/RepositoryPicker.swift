import AtriumProtocol
import SwiftUI

/// Repositories in the project, grouped under the branch each has checked out.
struct RepositoryPicker: View {
    let repositories: [GitRepositoryStatus]
    @Binding var selection: URL?

    var body: some View {
        Picker("Repository", selection: $selection) {
            ForEach(groups, id: \.branch) { group in
                Section(group.branch) {
                    ForEach(group.repositories, id: \.mainRepositoryURL) { repository in
                        Text(repository.name).tag(Optional(repository.mainRepositoryURL))
                    }
                }
            }
        }
    }

    /// Branches keep first-seen order so the menu stays stable across refreshes.
    private var groups: [(branch: String, repositories: [GitRepositoryStatus])] {
        var order: [String] = []
        var buckets: [String: [GitRepositoryStatus]] = [:]
        for repository in repositories {
            let branch = repository.branchName ?? "—"
            if buckets[branch] == nil { order.append(branch) }
            buckets[branch, default: []].append(repository)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
