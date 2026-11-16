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
/// A repository is listed for new pull requests when its tasks change, and
/// every two minutes for an hour after. Linked pull requests are read
/// together in one GraphQL call: every two minutes while they change, every
/// ten once they've been quiet for half an hour, and no more once they're
/// merged or closed.
@MainActor
@Observable
final class PullRequestTracker {
    /// The pull requests linked to each task, as last read.
    private(set) var linked: [String: [PullRequest]] = [:]

    /// A recently active task's checkouts in one repository, and when it
    /// first changed files there.
    private struct Interest {
        var checkouts: [URL]
        var since: Date
        var updatedAt: Date
    }

    /// When a linked pull request was last read, and when it last changed.
    private struct Read {
        var at: Date
        var changed: Date
    }

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var interests: [URL: [String: Interest]] = [:]
    /// The branches each task worked on in each repository.
    @ObservationIgnored private var branches: [String: [URL: Set<String>]] = [:]
    @ObservationIgnored private var lastListed: [URL: Date] = [:]
    @ObservationIgnored private var listing: Set<URL> = []
    /// Pull requests tasks opened that haven't been read yet, and the task that opened each.
    @ObservationIgnored private var opened: [URL: String] = [:]
    /// Ones GitHub didn't find, which aren't looked for again.
    @ObservationIgnored private var missing: Set<URL> = []
    @ObservationIgnored private var reads: [URL: Read] = [:]
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var lastFailedRead: Date?
    @ObservationIgnored private var poll: Task<Void, Never>?
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

    func start() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.listRecent()
                self?.readLinked()
            }
        }
    }

    /// A task's pull requests. The ones it `opened` are linked even once it's
    /// settled. While it's active, the branches of the checkouts it changed
    /// are noted each time it changes, and their repositories are listed for
    /// pull requests on them; `firstChanges` says when it first changed files
    /// in each, so a merged pull request from an earlier use of the same
    /// branch name isn't taken for its own.
    func pullRequests(
        for taskID: String, opened: Set<URL>, checkouts: [TaskCheckout], firstChanges: [URL: Date], updatedAt: Date, isActive: Bool
    ) -> [PullRequest] {
        let unread = opened.subtracting((linked[taskID] ?? []).map(\.url)).subtracting(missing)
            .filter { self.opened[$0] == nil }
        // Reading runs after this snapshot, outside its observation.
        if !unread.isEmpty {
            Task {
                for url in unread { self.opened[url] = taskID }
                self.readLinked()
            }
        }
        for checkout in checkouts {
            let repository = checkout.repository
            guard isActive else {
                interests[repository]?[taskID] = nil
                continue
            }
            let folder = checkout.worktree ?? repository
            let existing = interests[repository]?[taskID]
            var interest = existing ?? Interest(checkouts: [], since: firstChanges[repository] ?? updatedAt, updatedAt: updatedAt)
            let isNewCheckout = !interest.checkouts.contains(folder)
            if isNewCheckout { interest.checkouts.append(folder) }
            interest.since = min(interest.since, firstChanges[repository] ?? interest.since)
            let changed = interest.updatedAt != updatedAt
            interest.updatedAt = updatedAt
            interests[repository, default: [:]][taskID] = interest
            if changed || isNewCheckout && (existing != nil || branches[taskID]?[repository] == nil) {
                Task {
                    await self.noteBranches(of: taskID, in: repository)
                    self.list(repository)
                }
            } else if lastListed[repository] == nil {
                Task { self.list(repository) }
            }
        }
        return linked[taskID] ?? []
    }

    /// Notes the branches checked out where a task works in a repository,
    /// other than its default one, which isn't known for every repository.
    private func noteBranches(of taskID: String, in repository: URL) async {
        guard let defaultBranch = try? await GitExecutor().execute(GitDefaultBranchCommand(), at: repository)?.branch else { return }
        var noted = branches[taskID]?[repository] ?? []
        for folder in interests[repository]?[taskID]?.checkouts ?? [] {
            if let branch = await Self.branch(at: folder), branch != defaultBranch { noted.insert(branch) }
        }
        guard noted != branches[taskID]?[repository] ?? [] else { return }
        branches[taskID, default: [:]][repository] = noted
        save()
    }

    // MARK: - Listing repositories

    /// Lists again the repositories of tasks that changed in the last hour,
    /// which may have opened a pull request since.
    private func listRecent() {
        let recent = interests.compactMap { repository, tasks in
            tasks.values.contains { $0.updatedAt > .now.addingTimeInterval(-3600) } ? repository : nil
        }
        for repository in recent { list(repository, force: true) }
    }

    private func list(_ repository: URL, force: Bool = false) {
        guard !listing.contains(repository) else { return }
        // A repository `gh` can't read, as one without a GitHub remote, is tried again after a while.
        if let last = lastListed[repository], last > .now.addingTimeInterval(force ? -100 : -60) { return }
        listing.insert(repository)
        lastListed[repository] = .now
        Task {
            defer { listing.remove(repository) }
            let found: [GitHubPullRequest]
            do {
                let output = try await IntegrationProcess.run(
                    "gh", arguments: ["pr", "list", "--state", "all", "--limit", "100", "--json", GitHubPullRequest.fields],
                    directory: repository.path(percentEncoded: false), timeout: .seconds(30))
                found = try GitHubPullRequest.decode(output)
            } catch {
                log.info("Couldn't list pull requests in \(repository.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
                lastListed[repository] = .now.addingTimeInterval(600)
                return
            }
            link(found, in: repository)
        }
    }

    /// Updates the linked pull requests from a repository's, and links the
    /// ones on branches its active tasks worked on.
    private func link(_ found: [GitHubPullRequest], in repository: URL) {
        var updated = linked
        for (taskID, interest) in interests[repository] ?? [:] {
            let worked = branches[taskID]?[repository] ?? []
            for candidate in found where worked.contains(candidate.headRefName)
                && (candidate.isOpen || (candidate.closedAt ?? .distantPast) >= interest.since)
                && !(updated[taskID] ?? []).contains(where: { $0.url == candidate.url }) {
                updated[taskID, default: []].append(candidate.pullRequest)
            }
        }
        update(&updated, with: found)
        apply(updated)
    }

    // MARK: - Reading pull requests

    /// Reads the pull requests tasks opened, and the linked ones still open
    /// that are due, in one call.
    private func readLinked() {
        guard !isReading, lastFailedRead.map({ $0 < .now.addingTimeInterval(-300) }) ?? true else { return }
        var due = Set(opened.keys)
        for pullRequest in linked.values.joined() where pullRequest.state == .open || pullRequest.state == .draft {
            let read = reads[pullRequest.url]
            let interval: TimeInterval = (read?.changed ?? .distantPast) > .now.addingTimeInterval(-1800) ? 110 : 590
            if (read?.at ?? .distantPast) < .now.addingTimeInterval(-interval) { due.insert(pullRequest.url) }
        }
        guard !due.isEmpty else { return }
        let batch = Array(due.prefix(50))
        let (query, aliases) = GitHubPullRequest.query(reading: batch)
        for url in batch where !aliases.values.contains(url) {
            if opened.removeValue(forKey: url) != nil { missing.insert(url) }
        }
        guard !aliases.isEmpty else { return }
        isReading = true
        Task {
            let found: [URL: GitHubPullRequest?]
            do {
                // GitHub answers a query naming a pull request it can't find with an error beside the others.
                let output = try await IntegrationProcess.run(
                    "gh", arguments: ["api", "graphql", "-f", "query=\(query)"], timeout: .seconds(30), acceptedExitCodes: [0, 1])
                found = try GitHubPullRequest.decode(output, aliases: aliases)
            } catch {
                log.info("Couldn't read pull requests: \(error.localizedDescription, privacy: .public)")
                lastFailedRead = .now
                isReading = false
                return
            }
            var updated = linked
            for (url, pullRequest) in found {
                guard let pullRequest else {
                    if opened.removeValue(forKey: url) != nil { missing.insert(url) }
                    reads[url] = Read(at: .now, changed: reads[url]?.changed ?? .distantPast)
                    continue
                }
                if let taskID = opened.removeValue(forKey: url),
                   !(updated[taskID] ?? []).contains(where: { $0.url == pullRequest.url }) {
                    updated[taskID, default: []].append(pullRequest.pullRequest)
                }
            }
            update(&updated, with: found.values.compactMap { $0 })
            apply(updated)
            isReading = false
            if !opened.isEmpty { readLinked() }
        }
    }

    /// Replaces the linked pull requests among `found` with their latest.
    private func update(_ updated: inout [String: [PullRequest]], with found: [GitHubPullRequest]) {
        let latest = Dictionary(found.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        for pullRequest in found {
            reads[pullRequest.url] = Read(at: .now, changed: pullRequest.updatedAt ?? .distantPast)
        }
        for (taskID, pullRequests) in updated {
            updated[taskID] = pullRequests.map { latest[$0.url]?.pullRequest ?? $0 }
        }
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
