import Foundation
import Network

extension ClientHandler {
    func gitSubscribe(workspaceId: UUID) {
        gitSubscription?.invalidate()
        guard let store, let workspace = store.workspaces.first(where: { $0.id == workspaceId }) else {
            sendError("workspace not found")
            return
        }
        sendGitStatus(workspaceId: workspaceId)
        let sub = GitSubscription(workspace: workspace) { [weak self] in
            self?.sendGitStatus(workspaceId: workspaceId)
        }
        sub.start()
        gitSubscription = sub
    }

    func sendGitStatus(workspaceId: UUID) {
        guard let store, let workspace = store.workspaces.first(where: { $0.id == workspaceId }) else { return }
        let directoryURL = workspace.url
        let selectedPath = selectedGitRepoPaths[workspaceId]
        Task { [weak self] in
            let (status, resolvedPath) = await Self.fetchGitStatus(
                directoryURL: directoryURL,
                selectedPath: selectedPath
            )
            await MainActor.run {
                guard let self else { return }
                if let resolvedPath {
                    self.selectedGitRepoPaths[workspaceId] = resolvedPath
                }
                var msg = CompanionMessage(kind: .gitStatus)
                msg.workspaceId = workspaceId
                msg.gitStatus = status
                self.send(msg)
            }
        }
    }

    private static func resolveSnapshot(
        snapshots: [GitRepositoryStatusSnapshot],
        selectedPath: URL?
    ) -> GitRepositoryStatusSnapshot? {
        if let selectedPath,
           let match = snapshots.first(where: { $0.repositoryRootURL.path == selectedPath.path }) {
            return match
        }
        return snapshots.first
    }

    private static func fetchGitStatus(
        directoryURL: URL,
        selectedPath: URL?
    ) async -> (WireGitStatus, URL?) {
        let empty = WireGitStatus(
            hasRepository: false,
            branchName: nil,
            localBranches: [],
            stagedFiles: [],
            unstagedFiles: [],
            unpushedCommits: [],
            hasTrackingBranch: false,
            remoteAheadCount: 0
        )
        do {
            let snapshots = try await GitRepository.shared.statusSnapshots(in: directoryURL)
            guard let snap = resolveSnapshot(snapshots: snapshots, selectedPath: selectedPath) else {
                return (empty, nil)
            }
            let repos = snapshots.map {
                WireGitRepository(
                    path: $0.repositoryRootURL.path,
                    displayName: $0.repositoryRootURL.lastPathComponent,
                    branchName: $0.branchName
                )
            }
            let status = WireGitStatus(
                hasRepository: true,
                branchName: snap.branchName,
                localBranches: snap.localBranches,
                stagedFiles: snap.stagedFiles.map { wireGitFile($0) },
                unstagedFiles: snap.unstagedFiles.map { wireGitFile($0) },
                unpushedCommits: snap.unpushedCommits.map {
                    WireGitCommit(
                        hash: $0.hash,
                        shortHash: String($0.hash.prefix(7)),
                        message: $0.message
                    )
                },
                hasTrackingBranch: snap.hasTrackingBranch,
                remoteAheadCount: snap.remoteAheadCount,
                repositories: repos,
                selectedRepositoryPath: snap.repositoryRootURL.path
            )
            return (status, snap.repositoryRootURL)
        } catch {
            return (empty, nil)
        }
    }

    private static func wireGitFile(_ file: GitChangedFile) -> WireGitFile {
        WireGitFile(
            path: file.repositoryRelativePath,
            name: file.fileURL.lastPathComponent,
            status: file.kind.rawValue
        )
    }

    func performGitAction(
        workspaceId: UUID,
        _ action: @escaping (GitRepositoryStatusSnapshot) async throws -> Void
    ) {
        guard let store, let workspace = store.workspaces.first(where: { $0.id == workspaceId }) else {
            sendError("workspace not found")
            return
        }
        let directoryURL = workspace.url
        let selectedPath = selectedGitRepoPaths[workspaceId]
        Task { [weak self] in
            do {
                let snapshots = try await GitRepository.shared.statusSnapshots(in: directoryURL)
                guard let snap = Self.resolveSnapshot(snapshots: snapshots, selectedPath: selectedPath) else {
                    await MainActor.run { self?.sendError("no repository") }
                    return
                }
                try await action(snap)
            } catch {
                await MainActor.run { self?.sendError(error.localizedDescription) }
            }
            await MainActor.run { self?.sendGitStatus(workspaceId: workspaceId) }
        }
    }

    func sendFileDiff(workspaceId: UUID, path: String, stage: String) {
        guard let store, let workspace = store.workspaces.first(where: { $0.id == workspaceId }) else {
            sendError("workspace not found")
            return
        }
        let directoryURL = workspace.url
        let selectedPath = selectedGitRepoPaths[workspaceId]
        Task { [weak self] in
            let text = await Self.fileDiffText(
                directoryURL: directoryURL,
                selectedPath: selectedPath,
                path: path,
                stage: stage
            )
            await MainActor.run {
                guard let self else { return }
                var msg = CompanionMessage(kind: .gitFileDiffResult)
                msg.workspaceId = workspaceId
                msg.gitFilePath = path
                msg.gitDiffStage = stage
                msg.gitDiffText = text
                self.send(msg)
            }
        }
    }

    private static func fileDiffText(
        directoryURL: URL,
        selectedPath: URL?,
        path: String,
        stage: String
    ) async -> String {
        do {
            let snapshots = try await GitRepository.shared.statusSnapshots(in: directoryURL)
            guard let snap = resolveSnapshot(snapshots: snapshots, selectedPath: selectedPath) else { return "No repository." }
            let staged = (stage == "staged")
            let pool = staged ? snap.stagedFiles : snap.unstagedFiles
            guard let file = pool.first(where: { $0.repositoryRelativePath == path }) else {
                return "File not found in current changes."
            }
            let diffStage: GitDiffStage = staged ? .staged : .unstaged
            let reference = GitDiffReference(
                repositoryRootURL: snap.repositoryRootURL,
                fileURL: file.fileURL,
                repositoryRelativePath: file.repositoryRelativePath,
                stage: diffStage,
                kind: file.kind
            )
            return try await GitRepository.shared.rawDiffText(for: reference)
        } catch {
            return "Failed to load diff: \(error.localizedDescription)"
        }
    }


}
