import AtriumProtocol
import Foundation
import Observation
import OSLog

/// The pull requests of each task, read with `gh`. A pull request is linked
/// to a task when one of its commands opened it, or when its branch is one
/// the task worked on: checked out, other than the default branch, where it
/// changed files or committed, as of when it was last active there. Once
/// linked, it stays linked after the branch is merged or gone.
///
/// Client activity triggers discovery and status reads. Commands that open
/// pull requests trigger a read immediately.
@MainActor
@Observable
final class PullRequestTracker {
    /// The pull requests linked to each task, as last read.
    private(set) var linked: [String: [PullRequest]] = [:]

    private struct Interest {
        var checkouts: Set<URL> = []
        var since: Date
        var updatedAt: Date
        var isActive: Bool
    }

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var interests: [URL: [String: Interest]] = [:]
    /// The branches each task worked on in each repository.
    @ObservationIgnored private var branches: [String: [URL: Set<String>]] = [:]
    @ObservationIgnored private var pendingBranches: [URL: [String: Set<URL>]] = [:]
    @ObservationIgnored private var notingBranches: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var discoveryTasks: [URL: Set<String>] = [:]
    /// Pull requests opened by commands, awaiting metadata for these tasks.
    @ObservationIgnored private var opened: [URL: Set<String>] = [:]
    @ObservationIgnored private var canonicalURLs: [URL: URL] = [:]
    @ObservationIgnored private var pendingReads: Set<URL> = []
    @ObservationIgnored private var reading: Set<URL> = []
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var isSaveScheduled = false
    @ObservationIgnored private let log = Logger(subsystem: "com.SilverMarcs.Atrium", category: "PullRequests")

    private struct Saved: Codable {
        var linked: [String: [PullRequest]]
        var branches: [String: [URL: Set<String>]]?
    }

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            linked = saved.linked
            branches = saved.branches ?? [:]
        }
    }

    /// Records branch history as the task changes and immediately looks up
    /// URLs emitted by its commands. Branch discovery runs on refresh.
    func pullRequests(
        for taskID: String, opened: Set<URL>, checkouts: [TaskCheckout], firstChanges: [URL: Date], updatedAt: Date, isActive: Bool
    ) -> [PullRequest] {
        let current = linked[taskID] ?? []
        let knownURLs = Set(current.map(\.url))
        for url in opened where !knownURLs.contains(canonicalURLs[url] ?? url) {
            if self.opened[url, default: []].insert(taskID).inserted {
                enqueueReads([url])
            }
        }
        for checkout in checkouts {
            let repository = checkout.repository
            let folder = checkout.worktree ?? repository
            let existing = interests[repository]?[taskID]
            var interest = existing ?? Interest(
                since: firstChanges[repository] ?? updatedAt, updatedAt: updatedAt, isActive: isActive)
            let isNewCheckout = interest.checkouts.insert(folder).inserted
            interest.since = min(interest.since, firstChanges[repository] ?? interest.since)
            interest.updatedAt = updatedAt
            interest.isActive = isActive
            interests[repository, default: [:]][taskID] = interest
            // The current checkout may have moved on since a persisted task last used it.
            let needsBranch = if let existing {
                existing.updatedAt != updatedAt || isNewCheckout
                    || (!existing.isActive && branches[taskID]?[repository] == nil)
            } else {
                branches[taskID]?[repository] == nil
            }
            if isActive && needsBranch {
                noteBranches(of: taskID, in: repository, checkouts: interest.checkouts)
            }
        }
        return current
    }

    /// Refreshes one opened task, or the visible tasks of a connected client.
    /// An individual open can also discover PRs on a settled task's recorded branches.
    func refresh(taskIDs: Set<String>, includeSettled: Bool = false) {
        let urls = taskIDs.flatMap { taskID in
            (linked[taskID] ?? []).filter { includeSettled || $0.state != .merged }.map(\.url)
        }
        let unread = opened.keys.filter { opened[$0]?.isDisjoint(with: taskIDs) == false }
        enqueueReads(Set(urls).union(unread))

        for (repository, tasks) in interests {
            let candidates = Set(tasks.compactMap { taskID, interest in
                taskIDs.contains(taskID) && (includeSettled || interest.isActive) ? taskID : nil
            })
            if !candidates.isEmpty { list(repository, for: candidates) }
        }
    }

    private func noteBranches(of taskID: String, in repository: URL, checkouts: Set<URL>) {
        pendingBranches[repository, default: [:]][taskID, default: []].formUnion(checkouts)
        guard notingBranches[repository] == nil else { return }
        notingBranches[repository] = Task {
            defer { notingBranches[repository] = nil }
            while let pending = pendingBranches.removeValue(forKey: repository) {
                guard let defaultBranch = try? await GitExecutor().execute(GitDefaultBranchCommand(), at: repository)?.branch else { continue }
                var checkedOut: [URL: String] = [:]
                for folder in Set(pending.values.joined()) {
                    checkedOut[folder] = await Self.branch(at: folder)
                }
                for (taskID, folders) in pending {
                    let noted = Set(folders.compactMap { checkedOut[$0] }).subtracting([defaultBranch])
                    let saved = branches[taskID]?[repository] ?? []
                    guard !noted.isSubset(of: saved) else { continue }
                    branches[taskID, default: [:]][repository] = saved.union(noted)
                    save()
                }
            }
        }
    }

    // MARK: - Discovery

    private func list(_ repository: URL, for taskIDs: Set<String>) {
        let alreadyListing = discoveryTasks[repository] != nil
        discoveryTasks[repository, default: []].formUnion(taskIDs)
        guard !alreadyListing else { return }
        Task {
            defer { discoveryTasks[repository] = nil }
            await notingBranches[repository]?.value
            guard discoveryTasks[repository]?.contains(where: { branches[$0]?[repository]?.isEmpty == false }) == true
            else { return }

            let beforeListing = linked
            let found: [GitHubPullRequest]
            do {
                let output = try await IntegrationProcess.run(
                    "gh", arguments: ["pr", "list", "--state", "all", "--limit", "100", "--json", GitHubPullRequest.fields],
                    directory: repository.path(percentEncoded: false), timeout: .seconds(30))
                found = try GitHubPullRequest.decode(output)
            } catch {
                log.info("Couldn't list pull requests in \(repository.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
            await notingBranches[repository]?.value
            var updated = linked
            var discovered: [URL: PullRequest] = [:]
            for taskID in discoveryTasks[repository] ?? [] {
                guard let interest = interests[repository]?[taskID] else { continue }
                let worked = branches[taskID]?[repository] ?? []
                let known = Set((updated[taskID] ?? []).map(\.url))
                for candidate in found where worked.contains(candidate.headRefName)
                    && (candidate.isOpen || (candidate.closedAt ?? .distantPast) >= interest.since)
                    && !known.contains(candidate.url) {
                    if let pullRequest = discovered[candidate.url] {
                        updated[taskID, default: []].append(pullRequest)
                        continue
                    }
                    let before = beforeListing.values.lazy.flatMap { $0 }.first { $0.url == candidate.url }
                    let current = linked.values.lazy.flatMap { $0 }.first { $0.url == candidate.url }
                    // Preserve a badge that changed while the list request was in flight.
                    let pullRequest = if let current, current != before { current } else { candidate.pullRequest }
                    discovered[candidate.url] = pullRequest
                    updated[taskID, default: []].append(pullRequest)
                }
            }
            updateLinks(updated, with: discovered)
        }
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
        apply(updated.mapValues { $0.map { latest[$0.url] ?? $0 } })
    }

    private func apply(_ updated: [String: [PullRequest]]) {
        guard updated != linked else { return }
        linked = updated
        save()
    }

    /// The branch checked out in a folder, or nil when its HEAD is detached.
    private static func branch(at folder: URL) async -> String? {
        guard let output = try? await GitExecutor().runRawData(arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], at: folder) else { return nil }
        let branch = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    /// Writes once the current change is through.
    private func save() {
        guard !isSaveScheduled else { return }
        isSaveScheduled = true
        Task {
            isSaveScheduled = false
            guard let data = try? JSONEncoder().encode(Saved(linked: linked, branches: branches)) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
