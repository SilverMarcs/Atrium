import AtriumProtocol
import Foundation
import Observation
import OSLog

/// The pull requests of each task, read with `gh` from the repositories its
/// checkouts are in. A pull request is linked to a task when its branch is
/// the one checked out where the task changed files, and stays linked after
/// the branch is merged or gone. Each repository is read with one `gh` call,
/// at most once a minute while its tasks change, and every two minutes while
/// one of their pull requests is open.
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

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var interests: [URL: [String: Interest]] = [:]
    /// The repository of each linked pull request, which is where it's read again.
    @ObservationIgnored private var repositories: [URL: URL] = [:]
    @ObservationIgnored private var lastRead: [URL: Date] = [:]
    @ObservationIgnored private var reading: Set<URL> = []
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var isSaveScheduled = false
    @ObservationIgnored private let log = Logger(subsystem: "com.SilverMarcs.Atrium", category: "PullRequests")

    private struct Saved: Codable {
        var linked: [String: [PullRequest]]
        var repositories: [URL: URL]
    }

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            linked = saved.linked
            repositories = saved.repositories
        }
    }

    func start() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                self?.pollOpen()
            }
        }
    }

    /// A task's pull requests. While it's active, the repositories of the
    /// checkouts it changed are read for new ones; `firstChanges` says when it
    /// first changed files in each, so a merged pull request from an earlier
    /// use of the same branch name isn't taken for its own.
    func pullRequests(
        for taskID: String, checkouts: [TaskCheckout], firstChanges: [URL: Date], updatedAt: Date, isActive: Bool
    ) -> [PullRequest] {
        for checkout in checkouts {
            let repository = checkout.repository
            guard isActive else {
                interests[repository]?[taskID] = nil
                continue
            }
            let folder = checkout.worktree ?? repository
            var interest = interests[repository]?[taskID]
                ?? Interest(checkouts: [], since: firstChanges[repository] ?? updatedAt, updatedAt: updatedAt)
            if !interest.checkouts.contains(folder) { interest.checkouts.append(folder) }
            interest.since = min(interest.since, firstChanges[repository] ?? interest.since)
            let changed = interest.updatedAt != updatedAt
            interest.updatedAt = updatedAt
            interests[repository, default: [:]][taskID] = interest
            // Reading runs after this snapshot, outside its observation.
            if changed || lastRead[repository] == nil {
                Task { self.read(repository) }
            }
        }
        return linked[taskID] ?? []
    }

    /// Reads again the repositories with open pull requests, and those of
    /// tasks that changed in the last hour, which may have opened one since.
    private func pollOpen() {
        let open = Set(linked.values.joined().filter { $0.state == .open || $0.state == .draft }.compactMap { repositories[$0.url] })
        let recent = Set(interests.compactMap { repository, tasks in
            tasks.values.contains { $0.updatedAt > .now.addingTimeInterval(-3600) } ? repository : nil
        })
        for repository in open.union(recent) { read(repository, force: true) }
    }

    private func read(_ repository: URL, force: Bool = false) {
        guard !reading.contains(repository) else { return }
        // A repository `gh` can't read, as one without a GitHub remote, is tried again after a while.
        if let last = lastRead[repository], last > .now.addingTimeInterval(force ? -100 : -60) { return }
        reading.insert(repository)
        lastRead[repository] = .now
        Task {
            defer { reading.remove(repository) }
            let found: [GitHubPullRequest]
            do {
                let output = try await IntegrationProcess.run(
                    "gh", arguments: ["pr", "list", "--state", "all", "--limit", "100", "--json", GitHubPullRequest.fields],
                    directory: repository.path(percentEncoded: false), timeout: .seconds(30))
                found = try GitHubPullRequest.decode(output)
            } catch {
                log.info("Couldn't list pull requests in \(repository.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
                lastRead[repository] = .now.addingTimeInterval(600)
                return
            }
            await link(found, in: repository)
        }
    }

    /// Updates the linked pull requests from a repository's, and links the
    /// ones whose branch an active task has checked out.
    private func link(_ found: [GitHubPullRequest], in repository: URL) async {
        let defaultBranch = try? await GitExecutor().execute(GitDefaultBranchCommand(), at: repository)?.branch
        var matches: [String: [PullRequest]] = [:]
        for (taskID, interest) in interests[repository] ?? [:] {
            for folder in interest.checkouts {
                guard let branch = await Self.branch(at: folder), branch != defaultBranch else { continue }
                for candidate in found where candidate.headRefName == branch
                    && (candidate.isOpen || (candidate.closedAt ?? .distantPast) >= interest.since) {
                    matches[taskID, default: []].append(candidate.pullRequest)
                }
            }
        }
        let latest = Dictionary(found.map { ($0.url, $0.pullRequest) }, uniquingKeysWith: { first, _ in first })
        var updated = linked
        for (taskID, pullRequests) in updated {
            updated[taskID] = pullRequests.map { latest[$0.url] ?? $0 }
        }
        for (taskID, pullRequests) in matches {
            var list = updated[taskID] ?? []
            for pullRequest in pullRequests where !list.contains(where: { $0.url == pullRequest.url }) {
                list.append(pullRequest)
                repositories[pullRequest.url] = repository
            }
            updated[taskID] = list
        }
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
            guard let data = try? JSONEncoder().encode(Saved(linked: linked, repositories: repositories)) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
