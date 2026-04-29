import Foundation

actor GitRepository {
    static let shared = GitRepository()

    private let executor = GitExecutor()

    func containsRepository(at directoryURL: URL) async -> Bool {
        await !self.repositoryRoots(in: directoryURL).isEmpty
    }

    func statusSnapshots(in directoryURL: URL) async throws -> [GitRepositoryStatusSnapshot] {
        let directoryURL = directoryURL.standardizedFileURL
        let repositoryRootURLs = await self.repositoryRoots(in: directoryURL)

        return try await withThrowingTaskGroup(of: GitRepositoryStatusSnapshot.self) { group in
            for repositoryRootURL in repositoryRootURLs {
                group.addTask {
                    let entries = try await self.executor.execute(GitStatusCommand(), at: repositoryRootURL)

                    async let branchName = try? self.executor.execute(GitBranchNameCommand(), at: repositoryRootURL)
                    async let hasTracking = self.checkHasTrackingBranch(at: repositoryRootURL)
                    async let localBranches = (try? self.executor.execute(GitLocalBranchesCommand(), at: repositoryRootURL)) ?? []

                    let tracking = await hasTracking
                    let branch = await branchName
                    async let unpushedCommits = self.fetchUnpushedCommits(at: repositoryRootURL, hasTrackingBranch: tracking, branchName: branch)
                    async let remoteAheadCount = tracking ? ((try? self.executor.execute(GitRemoteAheadCountCommand(), at: repositoryRootURL)) ?? 0) : 0

                    var stagedFiles: [GitChangedFile] = []
                    var unstagedFiles: [GitChangedFile] = []

                    for entry in entries {
                        if let stagedKind = entry.stagedKind,
                           let fileURL = Self.fileURL(for: entry.path, in: repositoryRootURL, scopedTo: directoryURL) {
                            stagedFiles.append(GitChangedFile(fileURL: fileURL, repositoryRelativePath: entry.path, kind: stagedKind))
                        }
                        if let unstagedKind = entry.unstagedKind,
                           let fileURL = Self.fileURL(for: entry.path, in: repositoryRootURL, scopedTo: directoryURL) {
                            unstagedFiles.append(GitChangedFile(fileURL: fileURL, repositoryRelativePath: entry.path, kind: unstagedKind))
                        }
                    }

                    return GitRepositoryStatusSnapshot(
                        repositoryRootURL: repositoryRootURL,
                        branchName: branch,
                        localBranches: await localBranches,
                        stagedFiles: stagedFiles,
                        unstagedFiles: unstagedFiles,
                        unpushedCommits: await unpushedCommits,
                        remoteAheadCount: await remoteAheadCount,
                        hasTrackingBranch: tracking
                    )
                }
            }

            var snapshots: [GitRepositoryStatusSnapshot] = []
            for try await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots.sorted { $0.repositoryRootURL.path < $1.repositoryRootURL.path }
        }
    }

    func initializeRepository(at directoryURL: URL) async throws {
        try await self.executor.execute(GitInitCommand(), at: directoryURL)
    }

    func changedFileURLs(in directoryURL: URL) async throws -> Set<URL> {
        let snapshots = try await self.statusSnapshots(in: directoryURL)
        return Set(
            snapshots
                .flatMap { $0.stagedFiles + $0.unstagedFiles }
                .map { $0.fileURL.standardizedFileURL }
        )
    }

    func changedFileStatuses(in directoryURL: URL) async throws -> [URL: GitChangeKind] {
        let snapshots = try await self.statusSnapshots(in: directoryURL)
        var statuses: [URL: GitChangeKind] = [:]

        for snapshot in snapshots {
            for file in snapshot.unstagedFiles {
                statuses[file.fileURL.standardizedFileURL] = file.kind
            }
            for file in snapshot.stagedFiles {
                statuses[file.fileURL.standardizedFileURL] = file.kind
            }
        }

        return statuses
    }

    func gutterDiff(for fileURL: URL, in directoryURL: URL) async throws -> GutterDiffResult {
        let directoryURL = directoryURL.standardizedFileURL
        let fileURL = fileURL.standardizedFileURL
        let repositoryRootURLs = await self.repositoryRoots(in: directoryURL)

        for rootURL in repositoryRootURLs {
            let rootPath = rootURL.path(percentEncoded: false)
            let filePath = fileURL.path(percentEncoded: false)
            guard filePath.hasPrefix(rootPath) else { continue }

            let relativePath = String(filePath.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            async let unstagedRaw = self.executor.execute(
                GitGutterDiffCommand(relativePath: relativePath, stage: .unstaged),
                at: rootURL
            )
            async let stagedRaw = self.executor.execute(
                GitGutterDiffCommand(relativePath: relativePath, stage: .staged),
                at: rootURL
            )
            let unstaged = GutterDiffParser.parse(try await unstagedRaw, stage: .unstaged)
            let staged = GutterDiffParser.parse(try await stagedRaw, stage: .staged)
            return GutterDiffParser.merge(unstaged: unstaged, staged: staged)
        }

        return .empty
    }

    func diffFilePresentation(for reference: GitDiffReference) async throws -> DiffFilePresentation {
        if reference.kind == .untracked {
            // For untracked files, generate a synthetic diff
            let pres = try self.presentationForUntrackedFile(reference)
            let raw = """
            diff --git a/\(reference.repositoryRelativePath) b/\(reference.repositoryRelativePath)
            new file mode 100644
            --- /dev/null
            +++ b/\(reference.repositoryRelativePath)
            """
            let lines = pres.string.split(separator: "\n", omittingEmptySubsequences: false)
            let hunkHeader = "@@ -0,0 +1,\(max(lines.count, 1)) @@"
            let hunkLines = lines.map { "+" + $0 }
            let fullRaw = raw + "\n" + hunkHeader + "\n" + hunkLines.joined(separator: "\n") + "\n"
            let fileHeader = raw
            return DiffFilePresentation(raw: fullRaw, fileHeader: fileHeader)
        }

        let raw = try await self.executor.execute(GitDiffCommand(reference: reference), at: reference.repositoryRootURL)
        guard !raw.isEmpty else {
            return DiffFilePresentation(message: "No diff available.")
        }

        // Extract file header (everything before first @@)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var headerLines: [String] = []
        for line in lines {
            if line.hasPrefix("@@") { break }
            headerLines.append(line)
        }
        let fileHeader = headerLines.joined(separator: "\n")

        return DiffFilePresentation(raw: raw, fileHeader: fileHeader)
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

    func diffPresentation(for reference: GitDiffReference) async throws -> GitDiffPresentation {
        if reference.kind == .untracked {
            return try self.presentationForUntrackedFile(reference)
        }

        let raw = try await self.executor.execute(GitDiffCommand(reference: reference), at: reference.repositoryRootURL)
        guard !raw.isEmpty else {
            return GitDiffPresentation(message: "No diff available.")
        }
        return GitDiffPresentation(raw: raw)
    }

    /// Raw `git diff` output with `@@` hunk headers and `+`/`-` prefixes
    /// intact. The iOS companion needs the unparsed text so it can split
    /// hunks and color lines itself; the macOS view's `presentation.string`
    /// strips those markers because the editor renders them visually.
    func rawDiffText(for reference: GitDiffReference) async throws -> String {
        if reference.kind == .untracked {
            return try self.untrackedRawDiff(for: reference)
        }
        return try await self.executor.execute(GitDiffCommand(reference: reference), at: reference.repositoryRootURL)
    }

    func fullContextDiffPresentation(for reference: GitDiffReference) async throws -> GitDiffPresentation {
        if reference.kind == .untracked {
            return try self.presentationForUntrackedFile(reference)
        }

        let raw = try await self.executor.execute(
            GitFullContextDiffCommand(reference: reference),
            at: reference.repositoryRootURL
        )
        guard !raw.isEmpty else {
            return GitDiffPresentation(message: "No diff available.")
        }
        return GitDiffPresentation(raw: raw)
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

    func remoteURL(at repositoryRootURL: URL) async throws -> String {
        try await self.executor.execute(GitRemoteURLCommand(), at: repositoryRootURL)
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
        _ = try await self.executor.runWithExitCode(
            arguments: ["reset", "--hard", originalHEAD],
            at: repositoryRootURL
        )
        try await self.executor.execute(GitStashPopCommand(), at: repositoryRootURL)
        return .wouldConflict
    }

    func pullRebase(at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitPullRebaseCommand(), at: repositoryRootURL)
    }

    func rebaseBranch(_ branch: String, at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitRebaseBranchCommand(branch: branch), at: repositoryRootURL)
    }

    func fetch(at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitFetchCommand(), at: repositoryRootURL)
    }

    func commitLog(at repositoryRootURL: URL, limit: Int = 200) async throws -> [GitLogEntry] {
        try await self.executor.execute(GitLogCommand(limit: limit), at: repositoryRootURL)
    }

    func switchBranch(to branch: String, at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitSwitchCommand(branch: branch), at: repositoryRootURL)
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

    func stashAll(message: String, at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitStashWithMessageCommand(message: message), at: repositoryRootURL)
    }

    func canStashApplyCleanly(at repositoryRootURL: URL) async -> Bool {
        do {
            let diffData = try await self.executor.runRawData(
                arguments: ["stash", "show", "-p"],
                at: repositoryRootURL
            )
            let result = try await self.executor.run(
                arguments: ["apply", "--check"],
                stdinData: diffData,
                at: repositoryRootURL
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func stashPop(at repositoryRootURL: URL) async throws {
        try await self.executor.execute(GitStashPopCommand(), at: repositoryRootURL)
    }

    // MARK: - Private

    private func checkHasTrackingBranch(at repositoryRootURL: URL) async -> Bool {
        do {
            _ = try await self.executor.execute(GitTrackingBranchCommand(), at: repositoryRootURL)
            return true
        } catch {
            return false
        }
    }

    private func fetchUnpushedCommits(at repositoryRootURL: URL, hasTrackingBranch: Bool, branchName: String?) async -> [GitUnpushedCommit] {
        let commitEntries: [(hash: String, message: String)]
        if hasTrackingBranch {
            guard let entries = try? await self.executor.execute(
                GitUnpushedCommitListCommand(), at: repositoryRootURL
            ) else { return [] }
            commitEntries = entries
        } else {
            guard let entries = try? await self.executor.execute(
                GitLocalOnlyCommitListCommand(branchName: branchName), at: repositoryRootURL
            ) else { return [] }
            commitEntries = entries
        }
        guard !commitEntries.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, GitUnpushedCommit).self) { group in
            for (index, entry) in commitEntries.enumerated() {
                group.addTask {
                    let fileEntries = (try? await self.executor.execute(
                        GitCommitFilesCommand(hash: entry.hash), at: repositoryRootURL
                    )) ?? []

                    let files: [GitChangedFile] = fileEntries.compactMap { fileEntry in
                        guard let kind = Self.changeKindFromDiffTreeStatus(fileEntry.status) else { return nil }
                        let fileURL = repositoryRootURL.appending(path: fileEntry.path).standardizedFileURL
                        return GitChangedFile(fileURL: fileURL, repositoryRelativePath: fileEntry.path, kind: kind)
                    }

                    return (index, GitUnpushedCommit(hash: entry.hash, message: entry.message, files: files))
                }
            }

            var results: [(Int, GitUnpushedCommit)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
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

        return await withTaskGroup(of: URL?.self) { group in
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

    private func presentationForUntrackedFile(_ reference: GitDiffReference) throws -> GitDiffPresentation {
        let raw = try self.untrackedRawDiff(for: reference)
        return GitDiffPresentation(raw: raw)
    }

    private func untrackedRawDiff(for reference: GitDiffReference) throws -> String {
        let data = try Data(contentsOf: reference.fileURL)
        guard let string = String(data: data, encoding: .utf8) else {
            return "Binary diff preview is unavailable."
        }

        let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = max(lines.count, 1)
        let hunkLines = lines.map { "+" + $0 }
        return """
        diff --git a/\(reference.repositoryRelativePath) b/\(reference.repositoryRelativePath)
        new file mode 100644
        --- /dev/null
        +++ b/\(reference.repositoryRelativePath)
        @@ -0,0 +1,\(lineCount) @@
        \(hunkLines.joined(separator: "\n"))
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

struct GitRepositoryStatusSnapshot: Equatable {
    var repositoryRootURL: URL
    var branchName: String?
    var localBranches: [String]
    var stagedFiles: [GitChangedFile]
    var unstagedFiles: [GitChangedFile]
    var unpushedCommits: [GitUnpushedCommit]
    var remoteAheadCount: Int
    var hasTrackingBranch: Bool

    var isDirty: Bool {
        !stagedFiles.isEmpty || !unstagedFiles.isEmpty
    }
}

struct GitUnpushedCommit: Equatable, Identifiable {
    var id: String { hash }
    var hash: String
    var message: String
    var files: [GitChangedFile]
}

struct GitLogEntry: Equatable, Identifiable, Sendable {
    var id: String { hash }
    var hash: String
    var shortHash: String
    var author: String
    var date: Date?
    var subject: String
}

struct GitChangedFile: Equatable, Hashable {
    var fileURL: URL
    var repositoryRelativePath: String
    var kind: GitChangeKind
}

enum GitChangeKind: String, Equatable, Hashable, Codable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case untracked
    case typeChanged
    case conflicted

    var statusSymbol: String {
        switch self {
            case .added: "A"
            case .modified: "M"
            case .deleted: "D"
            case .renamed: "R"
            case .copied: "C"
            case .untracked: "A"
            case .typeChanged: "T"
            case .conflicted: "U"
        }
    }
}

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

struct GitStatusCommand: GitCommand {
    var arguments: [String] {
        ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
    }

    func parse(output: String) throws -> [GitStatusEntry] {
        GitStatusParser.parse(output)
    }
}

struct GitBranchNameCommand: GitCommand {
    var arguments: [String] {
        ["branch", "--show-current"]
    }

    func parse(output: String) throws -> String? {
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
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

private struct GitRemoteURLCommand: GitCommand {
    var arguments: [String] { ["remote", "get-url", "origin"] }
    func parse(output: String) throws -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GitTrackingBranchCommand: GitCommand {
    var arguments: [String] { ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"] }
    func parse(output: String) throws -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GitPullCommand: GitCommand {
    var arguments: [String] { ["pull"] }
    func parse(output: String) throws { }
}

private struct GitPullRebaseCommand: GitCommand {
    var arguments: [String] { ["pull", "--rebase"] }
    func parse(output: String) throws { }
}

private struct GitRebaseBranchCommand: GitCommand {
    let branch: String
    var arguments: [String] { ["rebase", branch] }
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
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

private struct GitStashWithMessageCommand: GitCommand {
    let message: String
    var arguments: [String] { ["stash", "push", "--include-untracked", "-m", message] }
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

enum PullPreservingResult: Equatable, Sendable {
    case clean
    case wouldConflict
}

private struct GitRemoteAheadCountCommand: GitCommand {
    var arguments: [String] {
        ["rev-list", "HEAD..@{u}", "--count"]
    }

    func parse(output: String) throws -> Int {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

private struct GitUnpushedCommitListCommand: GitCommand {
    var arguments: [String] {
        ["log", "@{u}..HEAD", "--pretty=format:%H%x00%s"]
    }

    func parse(output: String) throws -> [(hash: String, message: String)] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\0", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (hash: String(parts[0]), message: String(parts[1]))
        }
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
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\0", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (hash: String(parts[0]), message: String(parts[1]))
        }
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

// MARK: - Status Parser

enum GitStatusParser {
    static func parse(_ output: String) -> [GitStatusEntry] {
        guard !output.isEmpty else { return [] }

        let entries = output.split(separator: "\0", omittingEmptySubsequences: false)
        var results: [GitStatusEntry] = []
        var index = 0

        while index < entries.count {
            let entry = String(entries[index])
            guard entry.count >= 3 else { index += 1; continue }

            guard
                let indexStatus = GitStatusCode(rawValue: entry[entry.startIndex]),
                let workTreeStatus = GitStatusCode(rawValue: entry[entry.index(after: entry.startIndex)])
            else { index += 1; continue }

            let isRenamedOrCopied = [.renamed, .copied].contains(indexStatus) || [.renamed, .copied].contains(workTreeStatus)
            let path = String(entry.dropFirst(3))
            results.append(GitStatusEntry(path: path, indexStatus: indexStatus, workTreeStatus: workTreeStatus))
            index += isRenamedOrCopied ? 2 : 1
        }

        return results
    }
}
