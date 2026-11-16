import AtriumProtocol
import Foundation

/// A pull request as `gh pr list --json` or GitHub's GraphQL API describes it.
nonisolated struct GitHubPullRequest: Decodable, Sendable {
    /// The fields asked for, which are all `gh` returns.
    static let fields = "number,title,url,state,isDraft,headRefName,reviewDecision,statusCheckRollup,closedAt,updatedAt"

    struct Check: Decodable, Sendable {
        /// A check run's progress and result.
        var status: String?
        var conclusion: String?
        /// A commit status's state, which stands for both.
        var state: String?
    }

    /// The head commit, whose checks GraphQL sums up in one state.
    struct Commits: Decodable, Sendable {
        struct Node: Decodable, Sendable {
            struct Commit: Decodable, Sendable {
                struct Rollup: Decodable, Sendable { var state: String }
                var statusCheckRollup: Rollup?
            }
            var commit: Commit
        }
        var nodes: [Node]
    }

    var number: Int
    var title: String
    var url: URL
    var state: String
    var isDraft: Bool
    var headRefName: String
    var reviewDecision: String?
    var statusCheckRollup: [Check]?
    var commits: Commits?
    var closedAt: Date?
    var updatedAt: Date?

    static func decode(_ data: Data) throws -> [GitHubPullRequest] {
        try decoder.decode([GitHubPullRequest].self, from: data)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    var isOpen: Bool { state == "OPEN" }

    var pullRequest: PullRequest {
        // github.com/<owner>/<name>/pull/<number>
        let path = url.pathComponents.dropFirst()
        return PullRequest(
            url: url, number: number, title: title, repository: path.prefix(2).joined(separator: "/"),
            branch: headRefName, state: pullRequestState, checks: checks, review: review)
    }

    private var pullRequestState: PullRequest.State {
        switch state {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: isDraft ? .draft : .open
        }
    }

    private var review: PullRequest.Review? {
        switch reviewDecision {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .required
        default: nil
        }
    }

    /// Failing if any check failed, running if any hasn't finished, nil when there are none.
    private var checks: PullRequest.Checks? {
        if let commits {
            return switch commits.nodes.last?.commit.statusCheckRollup?.state {
            case "FAILURE", "ERROR": .failing
            case "PENDING", "EXPECTED": .pending
            case "SUCCESS": .passing
            default: nil
            }
        }
        let checks = statusCheckRollup ?? []
        guard !checks.isEmpty else { return nil }
        let failed: Set = ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"]
        if checks.contains(where: { failed.contains($0.conclusion ?? "") || failed.contains($0.state ?? "") }) { return .failing }
        let running: Set = ["PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"]
        if checks.contains(where: { running.contains($0.status ?? "") || running.contains($0.state ?? "") }) { return .pending }
        return .passing
    }
}

// MARK: - Reading several at once

nonisolated extension GitHubPullRequest {
    /// One GraphQL query reading the pull requests at `urls`, and the URL each
    /// of its aliases reads. URLs that aren't GitHub pull requests are left out.
    static func query(reading urls: [URL]) -> (query: String, aliases: [String: URL]) {
        var aliases: [String: URL] = [:]
        var reads: [String] = []
        for url in urls {
            let path = Array(url.pathComponents.dropFirst())
            guard url.host() == "github.com", path.count == 4, path[2] == "pull", let number = Int(path[3]),
                  path[0].wholeMatch(of: /[\w.-]+/) != nil, path[1].wholeMatch(of: /[\w.-]+/) != nil else { continue }
            let alias = "p\(reads.count)"
            aliases[alias] = url
            reads.append(#"\#(alias):repository(owner:"\#(path[0])",name:"\#(path[1])"){pullRequest(number:\#(number)){...f}}"#)
        }
        let fragment = "fragment f on PullRequest{number title url state isDraft headRefName reviewDecision closedAt updatedAt "
            + "commits(last:1){nodes{commit{statusCheckRollup{state}}}}}"
        return ("query{\(reads.joined(separator: " "))}\(fragment)", aliases)
    }

    /// The pull requests a query's response holds, by the URL each alias read;
    /// nil for one GitHub didn't find. Throws when the response has no data.
    static func decode(_ data: Data, aliases: [String: URL]) throws -> [URL: GitHubPullRequest?] {
        struct Response: Decodable {
            struct Repository: Decodable { var pullRequest: GitHubPullRequest? }
            var data: [String: Repository?]?
        }
        guard let read = try decoder.decode(Response.self, from: data).data else {
            throw CocoaError(.coderValueNotFound)
        }
        var found: [URL: GitHubPullRequest?] = [:]
        for (alias, url) in aliases {
            found[url] = .some((read[alias] ?? nil)?.pullRequest)
        }
        return found
    }
}
