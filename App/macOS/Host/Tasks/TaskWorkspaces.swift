import Foundation

/// Where each task worked, kept by the host as the task works rather than
/// worked out again from its history whenever it's shown: each checkout of
/// its project's repositories it changed files in, or ran its commands in
/// when that's a linked worktree, with the branch checked out there when it
/// last did. Saved, so a task keeps its branches once their worktrees are
/// removed and its pull requests can still be found by them.
@MainActor
final class TaskWorkspaces {
    nonisolated struct Workspace: Codable, Sendable, Hashable {
        var checkout: TaskCheckout
        /// The branch checked out there when the task last worked there;
        /// nil for a detached HEAD, or when it's not known which it was.
        var branch: String?
        var firstUsed: Date
        var lastUsed: Date
    }

    /// Task ID → the checkouts it worked in, the most recently used first.
    private var workspaces: [String: [Workspace]] = [:]

    /// What a task's workspaces were last worked out from, so unchanged tasks are skipped.
    private struct Input: Equatable {
        var folders: [String: Date]
        var currentDirectory: String?
        var updatedAt: Date
        var repositories: Set<String>
    }

    private var inputs: [String: Input] = [:]
    /// Folder → the checkout it's in, and whether the folder existed when that was found.
    private var located: [String: (exists: Bool, checkout: TaskCheckout?)] = [:]
    private let file: URL
    private var saveTask: Task<Void, Never>?

    /// Workspaces unused this long are forgotten.
    private static let retention: TimeInterval = 60 * 86_400
    /// The most kept for a task, newest first.
    private static let limit = 12
    /// How old work can be for the branch checked out now to be the one it was on.
    private static let branchAge: TimeInterval = 10 * 60

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: [Workspace]].self, from: data) {
            let cutoff = Date.now.addingTimeInterval(-Self.retention)
            workspaces = saved.compactMapValues { kept in
                let kept = kept.filter { $0.lastUsed > cutoff }
                return kept.isEmpty ? nil : kept
            }
        }
    }

    /// The checkouts a task worked in among these repositories (main checkout
    /// paths), the most recently used first. A worktree moved since is where
    /// it went, and one removed is its repository's main checkout, still with
    /// the branch the task worked on there.
    func workspaces(of taskID: String, in repositories: Set<String>) -> [Workspace] {
        (workspaces[taskID] ?? []).compactMap { workspace in
            guard repositories.contains(workspace.checkout.repository.filePath) else { return nil }
            var workspace = workspace
            workspace.checkout = current(workspace)
            return workspace
        }
    }

    /// The checkout a folder is in now, following a worktree that moved or was removed.
    func checkout(at path: String, lastUsed: Date?) -> TaskCheckout? {
        let exists = FileManager.default.fileExists(atPath: path)
        if let cached = located[path], cached.exists == exists { return cached.checkout }
        let checkout = GitCheckout(locating: URL(filePath: path, directoryHint: .isDirectory), lastUsed: lastUsed).map {
            TaskCheckout(repository: $0.mainCheckoutURL, worktree: $0.linkedWorktreeURL)
        }
        located[path] = (exists, checkout)
        return checkout
    }

    /// Notes where a task worked as of its latest activity: the folders its
    /// edits and commits went to, each as of when, and the folder its
    /// commands last ran in. Only the repositories its project has count.
    func record(_ taskID: String, edits: AgentEdits, currentDirectory: String?, updatedAt: Date, repositories: Set<String>) {
        let input = Input(folders: edits.folders, currentDirectory: currentDirectory, updatedAt: updatedAt, repositories: repositories)
        guard inputs[taskID] != input else { return }
        inputs[taskID] = input

        var used: [(checkout: TaskCheckout, date: Date)] = edits.folders.compactMap { folder, date in
            checkout(at: folder, lastUsed: date).map { ($0, date) }
        }
        // An agent that went into a worktree works there, whatever it changed
        // files with; the main checkout counts only once it changes files there.
        if let currentDirectory, let checkout = checkout(at: currentDirectory, lastUsed: updatedAt), checkout.worktree != nil {
            used.append((checkout, updatedAt))
        }

        let saved = workspaces[taskID] ?? []
        // Stored as where they are now, so a moved worktree stays one workspace.
        var updated = saved.map { workspace in
            var workspace = workspace
            workspace.checkout = current(workspace)
            return workspace
        }
        for (checkout, date) in used where repositories.contains(checkout.repository.filePath) {
            guard let index = updated.firstIndex(where: { $0.checkout == checkout }) else {
                updated.append(Workspace(checkout: checkout, branch: Self.branch(of: checkout, at: date), firstUsed: date, lastUsed: date))
                continue
            }
            updated[index].firstUsed = min(updated[index].firstUsed, date)
            // The branch is read again only when the task works there again,
            // so one checked out there later for other work isn't taken for its own.
            guard date > updated[index].lastUsed else { continue }
            updated[index].lastUsed = date
            updated[index].branch = Self.branch(of: checkout, at: date) ?? updated[index].branch
        }
        updated.sort { $0.lastUsed > $1.lastUsed }
        updated = Array(updated.prefix(Self.limit))
        guard updated != saved else { return }
        workspaces[taskID] = updated
        save()
    }

    /// Forgets a deleted task.
    func remove(_ taskID: String) {
        inputs[taskID] = nil
        guard workspaces.removeValue(forKey: taskID) != nil else { return }
        save()
    }

    private func current(_ workspace: Workspace) -> TaskCheckout {
        guard let worktree = workspace.checkout.worktree else { return workspace.checkout }
        return checkout(at: worktree.filePath, lastUsed: workspace.lastUsed) ?? workspace.checkout
    }

    /// The branch checked out where a task worked at `date`, as far as
    /// what's checked out now tells: a linked worktree keeps the branch it was
    /// made for, but a main checkout's may have been switched since for
    /// other work, so it's read only for work just done.
    private static func branch(of checkout: TaskCheckout, at date: Date) -> String? {
        guard checkout.worktree != nil || date > .now.addingTimeInterval(-branchAge) else { return nil }
        return GitCheckout.branch(at: checkout.worktree ?? checkout.repository)
    }

    /// Writes once changes pause, since a task working in a worktree updates on every reply.
    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let data = try? JSONEncoder().encode(workspaces) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
