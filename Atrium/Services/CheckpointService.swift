// A wild penguin appeared.
import Foundation

enum CheckpointError: LocalizedError {
    case gitFailed(String)
    case checkpointNotFound

    var errorDescription: String? {
        switch self {
        case .gitFailed(let msg): return "Git operation failed: \(msg)"
        case .checkpointNotFound: return "Checkpoint ref not found"
        }
    }
}

struct CheckpointService {

    struct GitRepo {
        let path: URL
        let relativePath: String
    }

    // MARK: - Discovery

    static func discoverGitRepos(in workspace: URL) -> [GitRepo] {
        var repos: [GitRepo] = []
        let fm = FileManager.default

        if fm.fileExists(atPath: workspace.appendingPathComponent(".git").path) {
            repos.append(GitRepo(path: workspace, relativePath: ""))
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return repos }

        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else { continue }
            if fm.fileExists(atPath: entry.appendingPathComponent(".git").path) {
                repos.append(GitRepo(path: entry, relativePath: entry.lastPathComponent))
            }
        }

        return repos
    }

    // MARK: - Capture

    static func captureCheckpoint(
        workspace: URL,
        chatId: String,
        turn: Int
    ) async throws -> [RepoSnapshot] {
        let repos = discoverGitRepos(in: workspace)
        var snapshots: [RepoSnapshot] = []

        for repo in repos {
            let refName = checkpointRef(chatId: chatId, turn: turn)
            try await captureRepoCheckpoint(repo: repo.path, refName: refName)
            snapshots.append(RepoSnapshot(relativePath: repo.relativePath, isShadow: false, refName: refName))
        }

        let rootIsGit = repos.contains { $0.relativePath.isEmpty }
        if !rootIsGit {
            let shadowGitDir = try await ensureShadowRepo(in: workspace, excluding: repos)
            let refName = checkpointRef(chatId: chatId, turn: turn)
            try await captureShadowCheckpoint(workspace: workspace, shadowGitDir: shadowGitDir, refName: refName)
            snapshots.append(RepoSnapshot(relativePath: "", isShadow: true, refName: refName))
        }

        return snapshots
    }

    // MARK: - Restore

    static func restoreCheckpoint(
        workspace: URL,
        snapshots: [RepoSnapshot]
    ) async throws {
        for snapshot in snapshots {
            if snapshot.isShadow {
                let shadowGitDir = workspace.appendingPathComponent(".atrium/shadow-git")
                try await restoreShadowCheckpoint(workspace: workspace, shadowGitDir: shadowGitDir, refName: snapshot.refName)
            } else {
                let repoPath = snapshot.relativePath.isEmpty
                    ? workspace
                    : workspace.appendingPathComponent(snapshot.relativePath)
                try await restoreRepoCheckpoint(repo: repoPath, refName: snapshot.refName)
            }
        }
    }

    // MARK: - Cleanup

    static func deleteCheckpoints(
        workspace: URL,
        chatId: String,
        afterTurn: Int,
        throughTurn: Int
    ) async {
        guard afterTurn < throughTurn else { return }
        let repos = discoverGitRepos(in: workspace)
        let shadowGitDir = workspace.appendingPathComponent(".atrium/shadow-git")
        let hasShadow = FileManager.default.fileExists(atPath: shadowGitDir.path)

        for turn in (afterTurn + 1)...throughTurn {
            let ref = checkpointRef(chatId: chatId, turn: turn)
            for repo in repos {
                try? await runGit(args: ["update-ref", "-d", ref], cwd: repo.path)
            }
            if hasShadow {
                try? await runGit(args: ["update-ref", "-d", ref], cwd: workspace, env: ["GIT_DIR": shadowGitDir.path])
            }
        }
    }

    // MARK: - Shadow Repo

    private static func ensureShadowRepo(in workspace: URL, excluding repos: [GitRepo]) async throws -> URL {
        let shadowGitDir = workspace.appendingPathComponent(".atrium/shadow-git")
        let fm = FileManager.default

        if !fm.fileExists(atPath: shadowGitDir.path) {
            try fm.createDirectory(at: shadowGitDir, withIntermediateDirectories: true)
            try await runGit(args: ["init", "--bare", shadowGitDir.path], cwd: workspace)
        }

        let excludeDir = shadowGitDir.appendingPathComponent("info")
        if !fm.fileExists(atPath: excludeDir.path) {
            try fm.createDirectory(at: excludeDir, withIntermediateDirectories: true)
        }

        var lines = [".atrium/"]
        for repo in repos where !repo.relativePath.isEmpty {
            lines.append(repo.relativePath + "/")
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: excludeDir.appendingPathComponent("exclude"), atomically: true, encoding: .utf8)

        return shadowGitDir
    }

    // MARK: - Ref Naming

    private static func checkpointRef(chatId: String, turn: Int) -> String {
        let encoded = Data(chatId.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "refs/atrium/checkpoints/\(encoded)/turn/\(turn)"
    }

    // MARK: - Git Operations

    private static let commitEnv: [String: String] = [
        "GIT_COMMITTER_NAME": "Atrium",
        "GIT_COMMITTER_EMAIL": "checkpoint@atrium",
        "GIT_AUTHOR_NAME": "Atrium",
        "GIT_AUTHOR_EMAIL": "checkpoint@atrium",
    ]

    private static func captureRepoCheckpoint(repo: URL, refName: String) async throws {
        let tmpIndex = repo.appendingPathComponent(".git/st-tmp-index").path
        var env = commitEnv
        env["GIT_INDEX_FILE"] = tmpIndex
        defer { try? FileManager.default.removeItem(atPath: tmpIndex) }

        try await runGit(args: ["add", "--all"], cwd: repo, env: env)
        let treeSha = try await runGit(args: ["write-tree"], cwd: repo, env: env)
        let commitSha = try await runGit(args: ["commit-tree", treeSha, "-m", "checkpoint"], cwd: repo, env: env)
        try await runGit(args: ["update-ref", refName, commitSha], cwd: repo)
    }

    private static func captureShadowCheckpoint(workspace: URL, shadowGitDir: URL, refName: String) async throws {
        let tmpIndex = shadowGitDir.appendingPathComponent("st-tmp-index").path
        var env = commitEnv
        env["GIT_DIR"] = shadowGitDir.path
        env["GIT_WORK_TREE"] = workspace.path
        env["GIT_INDEX_FILE"] = tmpIndex
        defer { try? FileManager.default.removeItem(atPath: tmpIndex) }

        try await runGit(args: ["add", "--all"], cwd: workspace, env: env)
        let treeSha = try await runGit(args: ["write-tree"], cwd: workspace, env: env)
        let commitSha = try await runGit(args: ["commit-tree", treeSha, "-m", "checkpoint"], cwd: workspace, env: env)

        var refEnv = commitEnv
        refEnv["GIT_DIR"] = shadowGitDir.path
        try await runGit(args: ["update-ref", refName, commitSha], cwd: workspace, env: refEnv)
    }

    // Restore against a throwaway index so the user's staged changes survive.
    // The working tree ends up at checkpoint state; the real index is untouched,
    // so any divergence shows as unstaged changes.
    private static func restoreRepoCheckpoint(repo: URL, refName: String) async throws {
        let tmpIndex = repo.appendingPathComponent(".git/st-restore-index").path
        let env = ["GIT_INDEX_FILE": tmpIndex]
        defer { try? FileManager.default.removeItem(atPath: tmpIndex) }

        try await runGit(args: ["read-tree", refName], cwd: repo, env: env)
        try await runGit(args: ["checkout-index", "-af"], cwd: repo, env: env)
        try await runGit(args: ["clean", "-fd"], cwd: repo, env: env)
    }

    private static func restoreShadowCheckpoint(workspace: URL, shadowGitDir: URL, refName: String) async throws {
        let tmpIndex = shadowGitDir.appendingPathComponent("st-restore-index").path
        let env: [String: String] = [
            "GIT_DIR": shadowGitDir.path,
            "GIT_WORK_TREE": workspace.path,
            "GIT_INDEX_FILE": tmpIndex,
        ]
        defer { try? FileManager.default.removeItem(atPath: tmpIndex) }

        try await runGit(args: ["read-tree", refName], cwd: workspace, env: env)
        try await runGit(args: ["checkout-index", "-af"], cwd: workspace, env: env)
        try await runGit(args: ["clean", "-fd"], cwd: workspace, env: env)
    }

    // MARK: - Process Runner

    @discardableResult
    private static func runGit(
        args: [String],
        cwd: URL,
        env: [String: String]? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = cwd

            if let env {
                var merged = ProcessInfo.processInfo.environment
                merged.merge(env) { _, new in new }
                process.environment = merged
            }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { proc in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? output
                    continuation.resume(throwing: CheckpointError.gitFailed(errMsg))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
