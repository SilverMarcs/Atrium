import AtriumProtocol
import Foundation

actor GitRepository {
    static let shared = GitRepository()

    private let executor = GitExecutor()
    private var repositoryRootsCache: [URL: (fingerprint: [String], roots: [URL])] = [:]
    private var lastFetchAttempts: [URL: Date] = [:]

    /// `worktreeOverrides` maps a repository's main root to a linked worktree root;
    /// an overridden repository is snapshotted at the worktree instead, so one repo
    /// can be viewed through a worktree without affecting its siblings.
    func statusSnapshots(in directoryURL: URL, worktreeOverrides: [URL: URL] = [:]) async throws -> [GitRepositoryStatus] {
        let directoryURL = directoryURL.standardizedFileURL
        // An overridden root can collide with a worktree that was also discovered
        // directly (worktree folder inside the scanned directory) — dedupe.
        var seenRootURLs = Set<URL>()
        let repositoryRootURLs = await self.repositoryRoots(in: directoryURL)
            .map { rootURL in
                guard let worktreeURL = worktreeOverrides[rootURL],
                      FileManager.default.fileExists(atPath: worktreeURL.path) else { return rootURL }
                return worktreeURL.standardizedFileURL.resolvingSymlinksInPath()
            }
            .filter { seenRootURLs.insert($0).inserted }

        return try await withThrowingTaskGroup(of: GitRepositoryStatus.self) { group in
            for repositoryRootURL in repositoryRootURLs {
                group.addTask {
                    var status = try await self.executor.execute(GitStatusCommand(), at: repositoryRootURL)

                    if !status.hasUpstream, let branchName = status.branchName {
                        let remoteRef = "origin/\(branchName)"
                        if let counts = try? await self.executor.execute(
                            GitAheadBehindAgainstRefCommand(remoteRef: remoteRef),
                            at: repositoryRootURL
                        ) {
                            status.hasUpstream = true
                            status.upstreamBranch = remoteRef
                            status.aheadCount = counts.ahead
                            status.behindCount = counts.behind
                        }
                    }

                    async let localBranches = (try? self.executor.execute(GitLocalBranchesCommand(), at: repositoryRootURL)) ?? []
                    async let worktrees = (try? self.worktrees(at: repositoryRootURL)) ?? []
                    let unpushedStatus = status
                    async let unpushedCommits = self.fetchUnpushedCommits(
                        at: repositoryRootURL,
                        hasTrackingBranch: unpushedStatus.hasUpstream,
                        aheadCount: unpushedStatus.aheadCount,
                        branchName: unpushedStatus.branchName,
                        upstreamRef: unpushedStatus.upstreamBranch
                    )

                    var stagedFiles: [GitChangedFile] = []
                    var unstagedFiles: [GitChangedFile] = []

                    // Scoping only narrows the view when the directory is a subfolder
                    // of the repo; an overridden worktree lives outside the directory
                    // entirely and must not be filtered against it.
                    let scopeURL = repositoryRootURL.isAncestor(of: directoryURL) ? directoryURL : repositoryRootURL

                    for entry in status.entries {
                        if let stagedKind = entry.stagedKind,
                           let fileURL = Self.fileURL(for: entry.path, in: repositoryRootURL, scopedTo: scopeURL) {
                            stagedFiles.append(GitChangedFile(fileURL: fileURL, repositoryRelativePath: entry.path, kind: stagedKind))
                        }
                        if let unstagedKind = entry.unstagedKind,
                           let fileURL = Self.fileURL(for: entry.path, in: repositoryRootURL, scopedTo: scopeURL) {
                            unstagedFiles.append(GitChangedFile(fileURL: fileURL, repositoryRelativePath: entry.path, kind: unstagedKind))
                        }
                    }

                    return GitRepositoryStatus(
                        repositoryRootURL: repositoryRootURL,
                        branchName: status.branchName,
                        localBranches: await localBranches,
                        worktrees: await worktrees,
                        stagedFiles: stagedFiles,
                        unstagedFiles: unstagedFiles,
                        unpushedCommits: await unpushedCommits,
                        remoteAheadCount: status.behindCount,
                        hasTrackingBranch: status.hasUpstream
                    )
                }
            }

            var snapshots: [GitRepositoryStatus] = []
            for try await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots.sorted { $0.repositoryRootURL.path < $1.repositoryRootURL.path }
        }
    }

    func initializeRepository(at directoryURL: URL) async throws {
        try await self.executor.execute(GitInitCommand(), at: directoryURL)
    }

    /// A working file's staged and unstaged changes, as raw diffs for the editor's gutter.
    func gutterDiff(for fileURL: URL, in directoryURL: URL) async throws -> (staged: String, unstaged: String) {
        let directoryURL = directoryURL.standardizedFileURL
        let filePath = fileURL.standardizedFileURL.path(percentEncoded: false)
        for rootURL in await self.repositoryRoots(in: directoryURL) {
            let rootPath = rootURL.path(percentEncoded: false)
            guard filePath.hasPrefix(rootPath) else { continue }
            let relativePath = String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            async let unstaged = self.executor.execute(GitGutterDiffCommand(relativePath: relativePath, stage: .unstaged), at: rootURL)
            async let staged = self.executor.execute(GitGutterDiffCommand(relativePath: relativePath, stage: .staged), at: rootURL)
            return (try await staged, try await unstaged)
        }
        return ("", "")
    }

    /// Unified diff text for one file. Untracked files get a synthetic all-added diff.
    func rawDiff(for reference: GitDiffReference) async throws -> String {
        guard reference.kind != .untracked else { return try self.untrackedDiff(reference) }
        return try await self.executor.execute(GitDiffCommand(reference: reference), at: reference.repositoryRootURL)
    }

    func applyPatch(_ patchText: String, reverse: Bool = false, cached: Bool = false, at repositoryRootURL: URL) async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".patch")
        try patchText.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await self.executor.execute(
            GitApplyPatchCommand(patchFilePath: tempURL.path, reverse: reverse, cached: cached),
            at: repositoryRootURL
        )
    }

    /// The file's diff with its whole content as context. Untracked files get a
    /// synthetic all-added diff.
    func rawFullContextDiff(for reference: GitDiffReference) async throws -> String {
        guard reference.kind != .untracked else { return try self.untrackedDiff(reference) }
        return try await self.executor.execute(GitFullContextDiffCommand(reference: reference), at: reference.repositoryRootURL)
    }

    /// Both sides of an image file's diff, as stored.
    func imageDiff(for reference: GitDiffReference) async -> (old: Data?, new: Data?) {
        let path = reference.repositoryRelativePath
        let root = reference.repositoryRootURL
        var old: Data?
        var new: Data?
        if reference.kind != .added && reference.kind != .untracked {
            let ref = switch reference.stage {
            case .unstaged: ""
            case .staged: "HEAD"
            case .commit(let hash): "\(hash)~1"
            }
            old = try? await self.fileData(at: path, ref: ref, repositoryRootURL: root)
        }
        if reference.kind != .deleted {
            switch reference.stage {
            case .unstaged:
                new = try? Data(contentsOf: reference.fileURL)
            case .staged:
                new = (try? await self.fileData(at: path, ref: "", repositoryRootURL: root)) ?? (try? Data(contentsOf: reference.fileURL))
            case .commit(let hash):
                new = try? await self.fileData(at: path, ref: hash, repositoryRootURL: root)
            }
        }
        return (old, new)
    }

    /// Returns the raw binary content of a file at a given git ref.
    /// - For unstaged diffs the "old" version lives in the index (`:path`).
    /// - For staged diffs the "old" version is HEAD (`HEAD:path`).
    /// - For commit diffs, the "old" is `commit^:path` and "new" is `commit:path`.
    func fileData(at relativePath: String, ref: String, repositoryRootURL: URL) async throws -> Data {
        try await self.executor.runRawData(
            arguments: ["show", "\(ref):\(relativePath)"],
            at: repositoryRootURL
        )
    }

    func stage(paths: [String], at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitStageCommand(paths: paths), at: repositoryRootURL)
    }

    func unstage(paths: [String], at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitUnstageCommand(paths: paths), at: repositoryRootURL)
    }

    func discardChanges(trackedPaths: [String], untrackedPaths: [String], at repositoryRootURL: URL) async throws {
        if !trackedPaths.isEmpty {
            try await self.executor.execute(GitDiscardCommand(paths: trackedPaths), at: repositoryRootURL)
        }
        if !untrackedPaths.isEmpty {
            try await self.executor.execute(GitCleanCommand(paths: untrackedPaths), at: repositoryRootURL)
        }
    }

    func discardAllChanges(at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitDiscardAllCommand(), at: repositoryRootURL)
        try await self.executor.execute(GitCleanUntrackedCommand(), at: repositoryRootURL)
    }

    func commit(message: String, at repositoryRootURL: URL) async throws {
        _ = try await self.executor.execute(GitCommitCommand(message: message), at: repositoryRootURL)
    }

    func push(at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitPushCommand(), at: repositoryRootURL)
    }

    func pushSetUpstream(branch: String, at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitPushSetUpstreamCommand(branch: branch), at: repositoryRootURL)
    }

    func pull(at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitPullCommand(), at: repositoryRootURL)
    }

    /// Pulls while preserving any staged/unstaged/untracked changes in the working tree.
    /// Stashes first, pulls, then re-applies. If re-apply would conflict, the working
    /// tree is rolled back exactly to its pre-pull state and `.wouldConflict` is returned.
    func pullPreservingChanges(at repositoryRootURL: URL) async throws -> PullPreservingResult {
        let originalHEAD = try await self.executor.execute(GitRevParseHeadCommand(), at: repositoryRootURL)

        try await self.executor.execute(GitStashCommand(), at: repositoryRootURL)

        do {
            try await self.executor.execute(GitPullCommand(), at: repositoryRootURL)
        } catch {
            try? await self.executor.execute(GitStashPopCommand(), at: repositoryRootURL)
            throw error
        }

        let applyResult = try await self.executor.runWithExitCode(
            arguments: ["stash", "apply", "--index"],
            at: repositoryRootURL
        )
        if applyResult.exitCode == 0 {
            try await self.executor.execute(GitStashDropCommand(), at: repositoryRootURL)
            return .clean
        }

        // Conflict: undo the pull and the partial apply, then restore the original tree.
        // If the tree can't be reset, the changes stay in the stash rather than
        // being popped onto a half-applied tree.
        let reset = try await self.executor.runWithExitCode(
            arguments: ["reset", "--hard", originalHEAD],
            at: repositoryRootURL
        )
        guard reset.exitCode == 0 else {
            throw GitError.commandFailed(command: "git reset --hard \(originalHEAD)", message: reset.stderr)
        }
        try await self.executor.execute(GitStashPopCommand(), at: repositoryRootURL)
        return .wouldConflict
    }

    func pullRebase(at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitPullRebaseCommand(), at: repositoryRootURL)
    }

    func fetch(at repositoryRootURL: URL) async throws {
        lastFetchAttempts[repositoryRootURL.standardizedFileURL.resolvingSymlinksInPath()] = Date()
        try await self.executor.execute(GitFetchCommand(), at: repositoryRootURL)
    }

    /// Skips the network when a fetch was attempted within `maxAge` — automatic
    /// refreshes (workspace/tab switches, branch changes) go through this so they
    /// don't wake the radio on every switch; explicit user refresh calls `fetch`.
    /// Attempts count, not successes, so an offline machine isn't retried per switch.
    func fetchIfStale(at repositoryRootURL: URL, maxAge: TimeInterval = 300) async throws {
        let key = repositoryRootURL.standardizedFileURL.resolvingSymlinksInPath()
        if let last = lastFetchAttempts[key], Date().timeIntervalSince(last) < maxAge { return }
        try await self.fetch(at: repositoryRootURL)
    }

    func commitLog(at repositoryRootURL: URL, limit: Int = 200) async throws -> [GitLogEntry] {
        try await self.executor.execute(GitLogCommand(limit: limit), at: repositoryRootURL)
    }

    func changedFiles(forCommit hash: String, at repositoryRootURL: URL) async throws -> [GitChangedFile] {
        let entries = try await self.executor.execute(GitCommitFilesCommand(hash: hash), at: repositoryRootURL)
        return entries.compactMap { entry in
            guard let kind = Self.changeKindFromDiffTreeStatus(entry.status) else { return nil }
            let fileURL = repositoryRootURL.appending(path: entry.path).standardizedFileURL
            return GitChangedFile(fileURL: fileURL, repositoryRelativePath: entry.path, kind: kind)
        }
    }

    func switchBranch(to branch: String, at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitSwitchCommand(branch: branch), at: repositoryRootURL)
    }

    func hasUncommittedChanges(at repositoryRootURL: URL) async -> Bool {
        let status = try? await self.executor.execute(GitStatusCommand(), at: repositoryRootURL)
        return !(status?.entries.isEmpty ?? true)
    }

    func createBranch(named name: String, at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitCreateBranchCommand(name: name), at: repositoryRootURL)
    }

    func undoLastCommit(at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitResetSoftCommand(), at: repositoryRootURL)
    }

    func amendCommitMessage(_ message: String, at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitAmendMessageCommand(message: message), at: repositoryRootURL)
    }

    func stashAll(at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitStashCommand(), at: repositoryRootURL)
    }

    // MARK: - Branch Management

    func allBranchesDetailed(at repositoryRootURL: URL) async throws -> GitBranchListing {
        async let localTask = executor.execute(GitAllBranchesRawCommand(), at: repositoryRootURL)
        async let remoteTask = executor.execute(GitRemoteBranchesRawCommand(), at: repositoryRootURL)
        async let worktreeTask = worktrees(at: repositoryRootURL)
        async let targetTask = executor.execute(GitDefaultBranchCommand(), at: repositoryRootURL)
        async let currentMergedTask = executor.execute(GitMergedBranchesRawCommand(), at: repositoryRootURL)

        let local = try await localTask
        let remote = try await remoteTask
        let worktrees = try await worktreeTask
        let target = try await targetTask
        let currentMerged = Set(try await currentMergedTask)

        // Work merged into the local default branch counts before it's pushed,
        // and work merged on the remote counts before it's pulled.
        let remoteTarget = target.flatMap { target in
            target.ref.hasPrefix("refs/remotes/") ? String(target.ref.dropFirst("refs/remotes/".count)) : nil
        }
        let localTarget = target.flatMap { target in local.contains { $0.name == target.branch } ? target.branch : nil }
        let mergeTargets = [localTarget.map { "refs/heads/\($0)" }, remoteTarget.map { "refs/remotes/\($0)" }].compactMap { $0 }
        var defaultMerged: Set<String> = []
        for ref in mergeTargets {
            defaultMerged.formUnion(try await executor.execute(
                GitMergedBranchesRawCommand(target: ref, includeRemotes: true), at: repositoryRootURL
            ))
        }
        let branches = local.map {
            GitBranchInfo(name: $0.name, isCurrent: $0.isCurrent, upstream: $0.upstream,
                          isMergedIntoCurrentBranch: currentMerged.contains($0.name),
                          isMergedIntoDefaultBranch: $0.name != localTarget && defaultMerged.contains($0.name))
        } + remote.map {
            GitBranchInfo(name: $0, isCurrent: false, upstream: nil, isRemote: true,
                          isMergedIntoDefaultBranch: $0 != remoteTarget && defaultMerged.contains($0))
        }

        // A worktree is merged once its commit is in the default branch and it
        // has nothing uncommitted: a fresh worktree with edits isn't merged yet.
        var mergedWorktrees: Set<URL> = []
        for worktree in worktrees where !worktree.isMain && !worktree.isBare && worktree.branch != localTarget {
            guard let head = worktree.head,
                  try await isAncestor(head, ofAny: mergeTargets, at: repositoryRootURL),
                  try await executor.execute(GitStatusCommand(), at: worktree.path).entries.isEmpty else { continue }
            mergedWorktrees.insert(worktree.path)
        }
        return GitBranchListing(branches: branches, worktrees: worktrees, mergeTarget: localTarget ?? remoteTarget,
                                mergedWorktrees: mergedWorktrees)
    }

    private func isAncestor(_ commit: String, ofAny refs: [String], at repositoryRootURL: URL) async throws -> Bool {
        for ref in refs {
            let result = try await executor.runWithExitCode(
                arguments: ["merge-base", "--is-ancestor", commit, ref], at: repositoryRootURL
            )
            guard result.exitCode == 0 || result.exitCode == 1 else {
                throw GitError.commandFailed(command: "git merge-base", message: result.stderr)
            }
            if result.exitCode == 0 { return true }
        }
        return false
    }

    func deleteBranch(_ name: String, force: Bool, at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitDeleteBranchCommand(name: name, force: force), at: repositoryRootURL)
    }

    // MARK: - Worktrees

    private func removeWorktree(_ worktree: GitWorktreeInfo, force: Bool = false, at repositoryRootURL: URL) async throws {
        // Git rechecks locked and dirty state when removing; only an explicit
        // force from the user discards a dirty worktree's files.
        try await self.executor.execute(GitRemoveWorktreeCommand(worktreeURL: worktree.path, force: force), at: repositoryRootURL)
    }

    func deleteWorktree(at worktreeURL: URL, in repositoryRootURL: URL, force: Bool = false) async throws {
        let worktrees = try await self.worktrees(at: repositoryRootURL)
        let worktree = try removableWorktree(at: worktreeURL, from: worktrees)
        if let branch = worktree.branch {
            guard !worktrees.contains(where: { $0.branch == branch && $0.path != worktree.path }) else {
                throw GitError.commandFailed(command: "git worktree remove", message: "This branch is also checked out in another worktree.")
            }
        }
        try await removeWorktree(worktree, force: force, at: repositoryRootURL)
        if let branch = worktree.branch {
            do {
                try await deleteBranch(branch, force: true, at: repositoryRootURL)
            } catch {
                throw GitError.commandFailed(command: "git branch -D", message: "The worktree folder was removed, but branch \"\(branch)\" could not be deleted. \(error.localizedDescription)")
            }
        }
    }

    private func removableWorktree(at worktreeURL: URL, from worktrees: [GitWorktreeInfo]) throws -> GitWorktreeInfo {
        let resolvedURL = worktreeURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let worktree = worktrees.first(where: {
            $0.path.standardizedFileURL.resolvingSymlinksInPath() == resolvedURL
        }) else {
            throw GitError.commandFailed(command: "git worktree remove", message: "This worktree no longer exists.")
        }
        if let reason = worktree.deletionUnavailableReason {
            throw GitError.commandFailed(command: "git worktree remove", message: reason)
        }
        return worktree
    }

    /// Lists every worktree of the repository, flagging the one whose root matches
    /// `repositoryRootURL` as `isCurrent` so callers can tell "here" from "elsewhere".
    func worktrees(at repositoryRootURL: URL) async throws -> [GitWorktreeInfo] {
        let list = try await self.executor.execute(GitWorktreeListCommand(), at: repositoryRootURL)
        let resolvedRoot = repositoryRootURL.standardizedFileURL.resolvingSymlinksInPath()
        return list.map { info in
            var info = info
            info.isCurrent = info.path.standardizedFileURL.resolvingSymlinksInPath() == resolvedRoot
            return info
        }
    }

    // MARK: - Private

    private func fetchUnpushedCommits(at repositoryRootURL: URL, hasTrackingBranch: Bool, aheadCount: Int, branchName: String?, upstreamRef: String? = nil) async -> [GitUnpushedCommit] {
        let commitEntries: [(hash: String, message: String)]
        if hasTrackingBranch {
            guard aheadCount > 0 else { return [] }
            let command = GitUnpushedCommitListCommand(upstreamRef: upstreamRef ?? "@{u}")
            guard let entries = try? await self.executor.execute(
                command, at: repositoryRootURL
            ) else { return [] }
            commitEntries = entries
        } else {
            guard let entries = try? await self.executor.execute(
                GitLocalOnlyCommitListCommand(branchName: branchName), at: repositoryRootURL
            ) else { return [] }
            commitEntries = entries
        }
        return commitEntries.map { GitUnpushedCommit(hash: $0.hash, message: $0.message) }
    }

    private nonisolated static func changeKindFromDiffTreeStatus(_ status: Character) -> GitChangeKind? {
        switch status {
            case "A": .added
            case "M": .modified
            case "D": .deleted
            case "R": .renamed
            case "C": .copied
            case "T": .typeChanged
            default: nil
        }
    }

    private func repositoryRoots(in directoryURL: URL) async -> [URL] {
        let directoryURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidates = self.candidateDirectories(in: directoryURL)

        let fingerprint = Self.repositoryLayoutFingerprint(directoryURL: directoryURL, candidates: candidates)
        if let cached = repositoryRootsCache[directoryURL], cached.fingerprint == fingerprint {
            return cached.roots
        }

        let roots = await self.discoverRepositoryRoots(in: directoryURL, candidates: candidates)
        repositoryRootsCache[directoryURL] = (fingerprint, roots)
        return roots
    }

    /// Cheap stat-based summary of everything root discovery depends on. Discovery
    /// spawns a `git rev-parse` process per child directory and the FS watcher
    /// re-triggers it up to once a second during active work, so it only re-runs
    /// when this changes: a candidate folder or a `.git` entry (file or directory)
    /// appears, disappears, or moves — including in the nearest ancestor.
    private nonisolated static func repositoryLayoutFingerprint(directoryURL: URL, candidates: [URL]) -> [String] {
        let fm = FileManager.default
        var fingerprint = candidates
            .map { "\($0.path)|\(fm.fileExists(atPath: $0.appendingPathComponent(".git").path))" }
            .sorted()
        var ancestor = directoryURL.deletingLastPathComponent()
        while ancestor.pathComponents.count > 1 {
            if fm.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                fingerprint.append("ancestor|\(ancestor.path)")
                break
            }
            ancestor = ancestor.deletingLastPathComponent()
        }
        return fingerprint
    }

    private func discoverRepositoryRoots(in directoryURL: URL, candidates: [URL]) async -> [URL] {
        await withTaskGroup(of: URL?.self) { group in
            for candidateDirectoryURL in candidates {
                group.addTask {
                    guard let repositoryRootURL = try? await self.executor.execute(
                        GitRepositoryRootCommand(), at: candidateDirectoryURL
                    ) else { return nil }

                    let resolvedRoot = repositoryRootURL.standardizedFileURL.resolvingSymlinksInPath()

                    // Accept if: workspace is inside or equal to the repo root,
                    // OR the repo root is inside the workspace (nested repo)
                    guard resolvedRoot == directoryURL
                            || resolvedRoot.isAncestor(of: directoryURL)
                            || directoryURL.isAncestor(of: resolvedRoot)
                    else { return nil }

                    return resolvedRoot
                }
            }

            var repositoryRootURLs: Set<URL> = []
            for await rootURL in group {
                if let rootURL { repositoryRootURLs.insert(rootURL) }
            }
            return repositoryRootURLs.sorted { $0.path < $1.path }
        }
    }

    private func candidateDirectories(in directoryURL: URL) -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isHiddenKey]

        let childDirectoryURLs = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: Array(resourceKeys)))?
            .filter {
                guard let values = try? $0.resourceValues(forKeys: resourceKeys) else { return false }
                return values.isDirectory == true && values.isPackage != true && values.isHidden != true
            } ?? []

        return [directoryURL] + childDirectoryURLs
    }

    private func untrackedDiff(_ reference: GitDiffReference) throws -> String {
        let data = try Data(contentsOf: reference.fileURL)
        guard let string = String(data: data, encoding: .utf8) else { return "" }
        let lines = string.diffLines
        return """
        diff --git a/\(reference.repositoryRelativePath) b/\(reference.repositoryRelativePath)
        new file mode 100644
        --- /dev/null
        +++ b/\(reference.repositoryRelativePath)
        @@ -0,0 +1,\(max(lines.count, 1)) @@
        \(lines.map { "+" + $0 }.joined(separator: "\n"))
        """
    }

    private nonisolated static func fileURL(for path: String, in repositoryRootURL: URL, scopedTo directoryURL: URL) -> URL? {
        let fileURL = repositoryRootURL.appending(path: path).standardizedFileURL
        let resolvedDir = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedFile = fileURL.resolvingSymlinksInPath()

        guard resolvedFile == resolvedDir || resolvedDir.isAncestor(of: resolvedFile) else { return nil }

        // Return the non-resolved URL so it matches FileItem URLs built from the original directory
        return fileURL
    }
}

// MARK: - URL Extension

extension URL {
    func isAncestor(of url: URL) -> Bool {
        let ancestorComponents = self.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let childComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard ancestorComponents.count < childComponents.count else { return false }
        return zip(ancestorComponents, childComponents).allSatisfy(==)
    }
}

// MARK: - Git Repository Root Command

private struct GitRepositoryRootCommand: GitCommand {
    var arguments: [String] {
        ["rev-parse", "--show-toplevel"]
    }

    func parse(output: String) throws -> URL {
        URL(filePath: output.trimmingCharacters(in: .whitespacesAndNewlines), directoryHint: .isDirectory)
    }
}

// MARK: - Data Types

// MARK: - Status Parsing

struct GitStatusEntry: Equatable {
    var path: String
    var indexStatus: GitStatusCode
    var workTreeStatus: GitStatusCode

    var stagedKind: GitChangeKind? {
        self.indexStatus.changeKind(isStaged: true)
    }

    var unstagedKind: GitChangeKind? {
        self.workTreeStatus.changeKind(isStaged: false)
    }
}

enum GitStatusCode: Character, Equatable {
    case unmodified = " "
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case updatedButUnmerged = "U"
    case untracked = "?"
    case ignored = "!"
    case typeChanged = "T"

    func changeKind(isStaged: Bool) -> GitChangeKind? {
        switch self {
            case .unmodified, .ignored: nil
            case .modified: .modified
            case .added: .added
            case .deleted: .deleted
            case .renamed: .renamed
            case .copied: .copied
            case .updatedButUnmerged: .conflicted
            case .untracked: isStaged ? nil : .untracked
            case .typeChanged: .typeChanged
        }
    }
}

// MARK: - Git Commands

struct GitStatusResult: Equatable {
    var branchName: String?
    var upstreamBranch: String?
    var hasUpstream: Bool = false
    var aheadCount: Int = 0
    var behindCount: Int = 0
    var entries: [GitStatusEntry] = []
}

struct GitStatusCommand: GitCommand {
    var arguments: [String] {
        ["status", "--branch", "--porcelain=v2", "-z", "--untracked-files=all"]
    }

    func parse(output: String) throws -> GitStatusResult {
        GitStatusParser.parse(output)
    }
}

struct GitGutterDiffCommand: GitCommand {
    let relativePath: String
    let stage: GutterHunkStage

    var arguments: [String] {
        switch stage {
        case .staged:
            ["diff", "--cached", "--no-color", "--no-ext-diff", "--unified=0", "--", relativePath]
        case .unstaged:
            ["diff", "--no-color", "--no-ext-diff", "--unified=0", "--", relativePath]
        }
    }

    func parse(output: String) throws -> String { output }
}

struct GitStageCommand: GitCommand {
    let paths: [String]
    var arguments: [String] { ["add", "--"] + paths }
    func parse(output: String) throws { }
}

struct GitUnstageCommand: GitCommand {
    let paths: [String]
    var arguments: [String] { ["reset", "HEAD", "--"] + paths }
    func parse(output: String) throws { }
}

struct GitDiscardCommand: GitCommand {
    let paths: [String]
    var arguments: [String] { ["checkout", "--"] + paths }
    func parse(output: String) throws { }
}

struct GitCleanCommand: GitCommand {
    let paths: [String]
    var arguments: [String] { ["clean", "-f", "--"] + paths }
    func parse(output: String) throws { }
}

struct GitDiscardAllCommand: GitCommand {
    var arguments: [String] { ["checkout", "--", "."] }
    func parse(output: String) throws { }
}

struct GitCleanUntrackedCommand: GitCommand {
    var arguments: [String] { ["clean", "-fd"] }
    func parse(output: String) throws { }
}

struct GitApplyPatchCommand: GitCommand {
    let patchFilePath: String
    let reverse: Bool
    let cached: Bool

    var arguments: [String] {
        var args = ["apply"]
        if reverse { args.append("--reverse") }
        if cached { args.append("--cached") }
        args.append("--unidiff-zero")
        args.append(patchFilePath)
        return args
    }

    func parse(output: String) throws {}
}

struct GitCommitCommand: GitCommand {
    let message: String
    var arguments: [String] { ["commit", "-m", message] }
    func parse(output: String) throws -> String { output }
}

private struct GitInitCommand: GitCommand {
    var arguments: [String] { ["init"] }
    func parse(output: String) throws { }
}

struct GitPushCommand: GitCommand {
    var arguments: [String] { ["push"] }
    func parse(output: String) throws { }
}

private struct GitPushSetUpstreamCommand: GitCommand {
    let branch: String
    var arguments: [String] { ["push", "--set-upstream", "origin", branch] }
    func parse(output: String) throws { }
}

struct GitPullCommand: GitCommand {
    var arguments: [String] { ["pull"] }
    func parse(output: String) throws { }
}

private struct GitPullRebaseCommand: GitCommand {
    var arguments: [String] { ["pull", "--rebase"] }
    func parse(output: String) throws { }
}

struct GitFetchCommand: GitCommand {
    var arguments: [String] { ["fetch", "--all"] }
    func parse(output: String) throws { }
}

private struct GitLocalBranchesCommand: GitCommand {
    var arguments: [String] {
        ["branch", "--format=%(refname:short)"]
    }

    func parse(output: String) throws -> [String] {
        parseNameList(output)
    }
}

private struct GitSwitchCommand: GitCommand {
    let branch: String
    var arguments: [String] { ["switch", branch] }
    func parse(output: String) throws { }
}

private struct GitCreateBranchCommand: GitCommand {
    let name: String
    var arguments: [String] { ["switch", "-c", name, "--no-track"] }
    func parse(output: String) throws { }
}

private struct GitResetSoftCommand: GitCommand {
    var arguments: [String] { ["reset", "--soft", "HEAD~1"] }
    func parse(output: String) throws { }
}

private struct GitAmendMessageCommand: GitCommand {
    let message: String
    var arguments: [String] { ["commit", "--amend", "-m", message] }
    func parse(output: String) throws { }
}

private struct GitStashCommand: GitCommand {
    var arguments: [String] { ["stash", "--include-untracked"] }
    func parse(output: String) throws { }
}

private struct GitStashPopCommand: GitCommand {
    var arguments: [String] { ["stash", "pop", "--index"] }
    func parse(output: String) throws { }
}

private struct GitStashDropCommand: GitCommand {
    var arguments: [String] { ["stash", "drop"] }
    func parse(output: String) throws { }
}

private struct GitRevParseHeadCommand: GitCommand {
    var arguments: [String] { ["rev-parse", "HEAD"] }
    func parse(output: String) throws -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GitAheadBehindAgainstRefCommand: GitCommand {
    let remoteRef: String
    var arguments: [String] {
        ["rev-list", "--left-right", "--count", "HEAD...\(remoteRef)"]
    }

    func parse(output: String) throws -> (ahead: Int, behind: Int) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2,
              let ahead = Int(parts[0]),
              let behind = Int(parts[1]) else {
            return (0, 0)
        }
        return (ahead, behind)
    }
}


/// `hash NUL subject` lines, as `--pretty=format:%H%x00%s` prints them.
private func parseCommitList(_ output: String) -> [(hash: String, message: String)] {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return trimmed.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        let parts = line.split(separator: "\0", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (hash: String(parts[0]), message: String(parts[1]))
    }
}

/// One name per line, as `--format=%(refname:short)` prints them.
private func parseNameList(_ output: String) -> [String] {
    output.split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

private struct GitUnpushedCommitListCommand: GitCommand {
    var upstreamRef: String = "@{u}"
    var arguments: [String] {
        ["log", "\(upstreamRef)..HEAD", "--pretty=format:%H%x00%s"]
    }

    func parse(output: String) throws -> [(hash: String, message: String)] {
        parseCommitList(output)
    }
}

private struct GitLocalOnlyCommitListCommand: GitCommand {
    var branchName: String?

    var arguments: [String] {
        var args = ["log", "HEAD", "--not"]
        if let branchName {
            args += ["--exclude=\(branchName)", "--branches"]
        }
        args += ["--remotes", "--pretty=format:%H%x00%s"]
        return args
    }

    func parse(output: String) throws -> [(hash: String, message: String)] {
        parseCommitList(output)
    }
}

private struct GitLogCommand: GitCommand {
    let limit: Int

    var arguments: [String] {
        [
            "log",
            "-n", String(limit),
            "--pretty=format:%H%x1f%h%x1f%an%x1f%aI%x1f%s",
        ]
    }

    func parse(output: String) throws -> [GitLogEntry] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        return trimmed.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5 else { return nil }
            let dateString = String(parts[3])
            let date = formatter.date(from: dateString) ?? fallbackFormatter.date(from: dateString)
            return GitLogEntry(
                hash: String(parts[0]),
                shortHash: String(parts[1]),
                author: String(parts[2]),
                date: date,
                subject: String(parts[4])
            )
        }
    }
}

private struct GitCommitFilesCommand: GitCommand {
    let hash: String

    var arguments: [String] {
        ["diff-tree", "--no-commit-id", "-r", "--name-status", hash]
    }

    func parse(output: String) throws -> [(status: Character, path: String)] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count >= 2, let status = parts[0].first else { return nil }
            let path = String(parts.last!)
            return (status: status, path: path)
        }
    }
}

private struct GitRemoteBranchesRawCommand: GitCommand {
    var arguments: [String] {
        ["for-each-ref", "--format=%(refname:short)%00%(symref)", "refs/remotes"]
    }

    func parse(output: String) throws -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1].isEmpty else { return nil }
            return String(parts[0])
        }
    }
}

private struct GitAllBranchesRawCommand: GitCommand {
    var arguments: [String] {
        ["branch", "--list", "--format=%(HEAD)%00%(refname:short)%00%(upstream:short)"]
    }

    func parse(output: String) throws -> [(name: String, isCurrent: Bool, upstream: String?)] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { return nil }
            let isCurrent = parts[0].trimmingCharacters(in: .whitespaces) == "*"
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let upstream = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : nil
            return (name, isCurrent, upstream)
        }
    }
}

private struct GitMergedBranchesRawCommand: GitCommand {
    var target: String = "HEAD"
    var includeRemotes = false

    var arguments: [String] {
        ["branch", includeRemotes ? "--all" : "--list", "--merged", target, "--format=%(refname:short)"]
    }

    func parse(output: String) throws -> [String] {
        parseNameList(output)
    }
}

private struct GitDeleteBranchCommand: GitCommand {
    let name: String
    let force: Bool
    var arguments: [String] {
        ["branch", force ? "-D" : "-d", name]
    }
    func parse(output: String) throws { }
}

private struct GitWorktreeListCommand: GitCommand {
    var arguments: [String] { ["worktree", "list", "--porcelain"] }
    func parse(output: String) throws -> [GitWorktreeInfo] {
        GitWorktreeParser.parse(output)
    }
}

/// Parses `git worktree list --porcelain`. Records are separated by a blank line;
/// each attribute is its own line — `worktree <path>` (always first), `HEAD <sha>`,
/// `branch refs/heads/<name>`, and the valueless flags `bare`, `detached`, `locked`.
enum GitWorktreeParser {
    static func parse(_ output: String) -> [GitWorktreeInfo] {
        var result: [GitWorktreeInfo] = []
        for block in output.components(separatedBy: "\n\n") {
            var path: URL?
            var branch: String?
            var head: String?
            var isBare = false, isDetached = false, isLocked = false

            for rawLine in block.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(rawLine)
                if let value = value(of: "worktree", in: line) {
                    path = URL(filePath: value, directoryHint: .isDirectory)
                } else if let value = value(of: "HEAD", in: line) {
                    head = value
                } else if let value = value(of: "branch", in: line) {
                    branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
                } else if line == "bare" {
                    isBare = true
                } else if line == "detached" {
                    isDetached = true
                } else if line == "locked" || line.hasPrefix("locked ") {
                    isLocked = true
                }
            }

            guard let path else { continue }
            result.append(GitWorktreeInfo(path: path, branch: branch, head: head, isBare: isBare, isDetached: isDetached, isLocked: isLocked))
        }
        // git lists the primary worktree first.
        if !result.isEmpty { result[0].isMain = true }
        return result
    }

    private static func value(of key: String, in line: String) -> String? {
        let prefix = key + " "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }
}

// MARK: - Status Parser

/// Parses `git status --branch --porcelain=v2 -z` output.
/// Each NUL-separated token is either a `# ...` header or a status entry whose
/// first character indicates type (`1`, `2`, `u`, `?`, `!`). Type `2` (rename/copy)
/// is followed by an extra NUL-separated token holding the original path.
enum GitStatusParser {
    static func parse(_ output: String) -> GitStatusResult {
        var result = GitStatusResult()
        guard !output.isEmpty else { return result }

        let tokens = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token.isEmpty { i += 1; continue }

            if token.hasPrefix("# ") {
                parseHeader(String(token.dropFirst(2)), into: &result)
                i += 1
                continue
            }

            guard let kind = token.first else { i += 1; continue }
            switch kind {
            case "1":
                if let entry = parseEntry(token, fieldsBeforePath: 8) {
                    result.entries.append(entry)
                }
                i += 1
            case "2":
                if let entry = parseEntry(token, fieldsBeforePath: 9) {
                    result.entries.append(entry)
                }
                i += 2
            case "u":
                if let entry = parseEntry(token, fieldsBeforePath: 10) {
                    result.entries.append(entry)
                }
                i += 1
            case "?":
                let path = String(token.dropFirst(2))
                result.entries.append(GitStatusEntry(path: path, indexStatus: .untracked, workTreeStatus: .untracked))
                i += 1
            default:
                i += 1
            }
        }

        return result
    }

    private static func parseHeader(_ body: String, into result: inout GitStatusResult) {
        if let value = stripPrefix(body, "branch.head ") {
            result.branchName = value == "(detached)" ? nil : value
        } else if let value = stripPrefix(body, "branch.upstream ") {
            result.upstreamBranch = value
            result.hasUpstream = true
        } else if let value = stripPrefix(body, "branch.ab ") {
            let parts = value.split(separator: " ")
            guard parts.count == 2 else { return }
            result.aheadCount = Int(parts[0].dropFirst()) ?? 0
            result.behindCount = Int(parts[1].dropFirst()) ?? 0
        }
    }

    private static func stripPrefix(_ string: String, _ prefix: String) -> String? {
        guard string.hasPrefix(prefix) else { return nil }
        return String(string.dropFirst(prefix.count))
    }

    private static func parseEntry(_ token: String, fieldsBeforePath: Int) -> GitStatusEntry? {
        guard token.count > 4 else { return nil }
        let xyStart = token.index(token.startIndex, offsetBy: 2)
        let yIndex = token.index(after: xyStart)
        // v2 uses "." for unmodified where v1 used " ".
        let xChar: Character = token[xyStart] == "." ? " " : token[xyStart]
        let yChar: Character = token[yIndex] == "." ? " " : token[yIndex]
        guard
            let indexStatus = GitStatusCode(rawValue: xChar),
            let workTreeStatus = GitStatusCode(rawValue: yChar)
        else { return nil }

        var spaceCount = 0
        var pathStart: String.Index?
        for index in token.indices where token[index] == " " {
            spaceCount += 1
            if spaceCount == fieldsBeforePath {
                pathStart = token.index(after: index)
                break
            }
        }
        guard let start = pathStart else { return nil }
        return GitStatusEntry(path: String(token[start...]), indexStatus: indexStatus, workTreeStatus: workTreeStatus)
    }
}
