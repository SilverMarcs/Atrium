import Foundation
import Observation
import OSLog

/// The pull requests of each task, read with `gh`. A pull request is linked
/// to a task when one of its commands opened it, or when its branch is one
/// the task worked on in a checkout (as `TaskWorkspaces` keeps them), other
/// than the default branch, and it's open or closed since the task first
/// worked there. Once linked, it stays linked after the branch is
/// merged or gone.
///
/// Client activity triggers discovery and status reads. Commands that open
/// pull requests trigger a read immediately.
@MainActor
@Observable
final class PullRequestTracker {
    /// The pull requests linked to each task, as last read.
    private(set) var linked: [String: [PullRequest]] = [:]
    /// The remote each repository has for each GitHub repository, by
    /// lowercased `owner/name`.
    private var remotes: [URL: [String: String]] = [:]

    @ObservationIgnored private let file: URL
    /// Repository → the tasks whose branches the listing in flight looks for.
    @ObservationIgnored private var discovery: [URL: [String: [TaskWorkspaces.Workspace]]] = [:]
    @ObservationIgnored private var defaultBranches: [URL: String] = [:]
    /// When each repository's pull requests were last listed.
    @ObservationIgnored private var listedAt: [URL: Date] = [:]
    /// Pull requests opened by commands, awaiting metadata for these tasks.
    @ObservationIgnored private var opened: [URL: Set<String>] = [:]
    @ObservationIgnored private var canonicalURLs: [URL: URL] = [:]
    @ObservationIgnored private var remotesRead: Set<URL> = []
    @ObservationIgnored private var pendingReads: Set<URL> = []
    @ObservationIgnored private var reading: Set<URL> = []
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var isSaveScheduled = false
    @ObservationIgnored private let log = Logger(subsystem: "com.SilverMarcs.Atrium", category: "PullRequests")

    private struct Saved: Codable {
        var linked: [String: [PullRequest]]
    }

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            linked = saved.linked
        }
    }

    /// A task's linked pull requests, each with the remote of one of these
    /// checkouts that's its repository, when one is known.
    func pullRequests(for taskID: String, checkouts: [TaskCheckout]) -> [PullRequest] {
        (linked[taskID] ?? []).map { pullRequest in
            var pullRequest = pullRequest
            let name = pullRequest.repository.lowercased()
            pullRequest.local = checkouts.lazy.compactMap { checkout in
                self.remotes[checkout.repository]?[name].map { PullRequest.Local(repository: checkout.repository, remote: $0) }
            }.first
            return pullRequest
        }
    }

    /// Reads pull requests a task's commands opened, once each, right away.
    func noteOpened(_ urls: Set<URL>, by taskID: String) {
        let known = Set((linked[taskID] ?? []).map(\.url))
        for url in urls where !known.contains(canonicalURLs[url] ?? url) {
            if opened[url, default: []].insert(taskID).inserted { enqueueReads([url]) }
        }
    }

    /// Reads the status of these tasks' pull requests, merged ones only with
    /// `includeMerged`, and looks for pull requests opened from the branches
    /// they worked on in these workspaces: with `recentListingsSuffice`, only
    /// in repositories not listed in the last minute.
    func refresh(_ tasks: [String: [TaskWorkspaces.Workspace]], includeMerged: Bool = false, recentListingsSuffice: Bool = false) {
        let taskIDs = Set(tasks.keys)
        let urls = taskIDs.flatMap { taskID in
            (linked[taskID] ?? []).filter { includeMerged || $0.state != .merged }.map(\.url)
        }
        let unread = opened.keys.filter { opened[$0]?.isDisjoint(with: taskIDs) == false }
        enqueueReads(Set(urls).union(unread))

        var byRepository: [URL: [String: [TaskWorkspaces.Workspace]]] = [:]
        for (taskID, workspaces) in tasks {
            for workspace in workspaces where workspace.branch != nil {
                byRepository[workspace.checkout.repository, default: [:]][taskID, default: []].append(workspace)
            }
        }
        for (repository, candidates) in byRepository {
            readRemotes(of: repository)
            if recentListingsSuffice, let listed = listedAt[repository], listed > .now.addingTimeInterval(-60) { continue }
            list(repository, for: candidates)
        }
    }

    /// Notes which GitHub repositories a repository's remotes are, once, so
    /// its pull requests can be reviewed there.
    private func readRemotes(of repository: URL) {
        guard remotesRead.insert(repository).inserted else { return }
        Task {
            guard let output = try? await GitExecutor().runRawData(arguments: ["remote", "-v"], at: repository) else { return }
            var found: [String: String] = [:]
            for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 2, let name = Self.gitHubRepository(remoteURL: String(fields[1])) else { continue }
                let remote = String(fields[0])
                // origin when several remotes are the same repository.
                if found[name] == nil || remote == "origin" { found[name] = remote }
            }
            if !found.isEmpty { remotes[repository] = found }
        }
    }

    /// `owner/name`, lowercased, of a GitHub remote's URL in any form Git
    /// takes: `git@github.com:owner/name.git`, `https://github.com/owner/name`, `ssh://…`.
    nonisolated static func gitHubRepository(remoteURL: String) -> String? {
        guard let match = remoteURL.firstMatch(of: #/github\.com[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?/?$/#) else { return nil }
        return "\(match.1)/\(match.2)".lowercased()
    }

    // MARK: - Discovery

    /// Lists a repository's pull requests once for every task that worked on
    /// one of its branches. Tasks asked for while a listing runs join it.
    private func list(_ repository: URL, for candidates: [String: [TaskWorkspaces.Workspace]]) {
        let alreadyListing = discovery[repository] != nil
        discovery[repository, default: [:]].merge(candidates) { $1 }
        guard !alreadyListing else { return }
        Task {
            defer { discovery[repository] = nil }
            let defaultBranch = await defaultBranch(of: repository)
            guard !branches(listedIn: repository, other: defaultBranch).isEmpty else { return }

            let beforeListing = linked
            let found: [GitHubPullRequest]
            do {
                let output = try await IntegrationProcess.run(
                    "gh", arguments: ["pr", "list", "--state", "all", "--limit", "100", "--json", GitHubPullRequest.fields],
                    directory: repository.path(percentEncoded: false), timeout: .seconds(30))
                found = try GitHubPullRequest.decode(output)
                listedAt[repository] = .now
            } catch {
                log.info("Couldn't list pull requests in \(repository.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
            var updated = linked
            var discovered: [URL: PullRequest] = [:]
            for (taskID, workspaces) in branches(listedIn: repository, other: defaultBranch) {
                let known = Set((updated[taskID] ?? []).map(\.url))
                for pullRequest in found where !known.contains(pullRequest.url) && workspaces.contains(where: { workspace in
                    workspace.branch == pullRequest.headRefName
                        && (pullRequest.isOpen || (pullRequest.closedAt ?? .distantPast) >= workspace.firstUsed)
                }) {
                    let linkedNow = discovered[pullRequest.url] ?? {
                        let before = beforeListing.values.lazy.flatMap { $0 }.first { $0.url == pullRequest.url }
                        let current = linked.values.lazy.flatMap { $0 }.first { $0.url == pullRequest.url }
                        // Preserve a badge that changed while the list request was in flight.
                        return if let current, current != before { current } else { pullRequest.pullRequest }
                    }()
                    discovered[pullRequest.url] = linkedNow
                    updated[taskID, default: []].append(linkedNow)
                }
            }
            updateLinks(updated, with: discovered)
        }
    }

    /// The workspaces the listing of a repository looks for, by task: those on
    /// a branch other than its default one.
    private func branches(listedIn repository: URL, other defaultBranch: String?) -> [String: [TaskWorkspaces.Workspace]] {
        (discovery[repository] ?? [:]).mapValues { $0.filter { $0.branch != defaultBranch } }.filter { !$0.value.isEmpty }
    }

    private func defaultBranch(of repository: URL) async -> String? {
        if let known = defaultBranches[repository] { return known }
        let branch = try? await GitExecutor().execute(GitDefaultBranchCommand(), at: repository)?.branch
        defaultBranches[repository] = branch
        return branch
    }

    // MARK: - Status

    private func enqueueReads(_ urls: Set<URL>) {
        pendingReads.formUnion(urls.subtracting(reading))
        guard !pendingReads.isEmpty, readTask == nil else { return }
        // Defer the read until the current observation or request is through,
        // so simultaneous refreshes share a GraphQL batch.
        readTask = Task {
            defer { readTask = nil }
            while !pendingReads.isEmpty {
                let newlyOpened = pendingReads.filter { opened[$0] != nil }
                let priorityBatch = newlyOpened.prefix(50)
                let batch = Array(priorityBatch) + pendingReads.subtracting(newlyOpened).prefix(50 - priorityBatch.count)
                reading = Set(batch)
                pendingReads.subtract(reading)
                await read(batch)
                reading.removeAll()
            }
        }
    }

    private func read(_ urls: [URL]) async {
        let (query, aliases) = GitHubPullRequest.query(reading: urls)
        guard !aliases.isEmpty else { return }
        let found: [URL: GitHubPullRequest?]
        do {
            // GitHub can return data for the other PRs alongside an alias error.
            let output = try await IntegrationProcess.run(
                "gh", arguments: ["api", "graphql", "-f", "query=\(query)"], timeout: .seconds(30), acceptedExitCodes: [0, 1])
            found = try GitHubPullRequest.decode(output, aliases: aliases)
        } catch {
            log.info("Couldn't read pull requests: \(error.localizedDescription, privacy: .public)")
            return
        }
        var updated = linked
        var latest: [URL: PullRequest] = [:]
        for (url, result) in found {
            guard let pullRequest = result?.pullRequest else { continue }
            latest[pullRequest.url] = pullRequest
            latest[url] = pullRequest
            if url != pullRequest.url { canonicalURLs[url] = pullRequest.url }
            for taskID in opened.removeValue(forKey: url) ?? [] {
                if !(updated[taskID] ?? []).contains(where: { $0.url == pullRequest.url }) {
                    updated[taskID, default: []].append(pullRequest)
                }
            }
        }
        updateLinks(updated, with: latest)
    }

    private func updateLinks(_ updated: [String: [PullRequest]], with latest: [URL: PullRequest]) {
        guard !latest.isEmpty else { return }
        let updated = updated.mapValues { $0.map { latest[$0.url] ?? $0 } }
        guard updated != linked else { return }
        linked = updated
        save()
    }

    /// Writes once the current change is through.
    private func save() {
        guard !isSaveScheduled else { return }
        isSaveScheduled = true
        Task {
            isSaveScheduled = false
            guard let data = try? JSONEncoder().encode(Saved(linked: linked)) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
