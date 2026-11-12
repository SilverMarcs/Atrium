import AtriumProtocol
import SwiftUI

/// Repositories in the project: first the ones the task changed files in,
/// then the others grouped under the branch each has checked out.
struct RepositoryPicker: View {
    let repositories: [GitRepositoryStatus]
    /// The repositories the task changed files in, the most recently changed first.
    var changed: [GitRepositoryStatus] = []
    @Binding var selection: URL?

    var body: some View {
        Picker("Repository", selection: $selection) {
            if !changed.isEmpty {
                Section("Changed in This Task") {
                    // Menus show the second line, its branch, as a subtitle.
                    ForEach(changed, id: \.mainRepositoryURL) { repository in
                        VStack {
                            Text(repository.name)
                            Text(repository.branchName ?? "—")
                        }
                        .tag(Optional(repository.mainRepositoryURL))
                    }
                }
            }
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
        for repository in repositories where !changed.contains(where: { $0.mainRepositoryURL == repository.mainRepositoryURL }) {
            let branch = repository.branchName ?? "—"
            if buckets[branch] == nil { order.append(branch) }
            buckets[branch, default: []].append(repository)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
