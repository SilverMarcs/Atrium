import AtriumProtocol
import Foundation

/// A pull request as `gh pr list --json` describes it.
nonisolated struct GitHubPullRequest: Decodable, Sendable {
    /// The fields asked for, which are all `gh` returns.
    static let fields = "number,title,url,state,isDraft,headRefName,reviewDecision,statusCheckRollup,closedAt"

    struct Check: Decodable, Sendable {
        /// A check run's progress and result.
        var status: String?
        var conclusion: String?
        /// A commit status's state, which stands for both.
        var state: String?
    }

    var number: Int
    var title: String
    var url: URL
    var state: String
    var isDraft: Bool
    var headRefName: String
    var reviewDecision: String?
    var statusCheckRollup: [Check]?
    var closedAt: Date?

    static func decode(_ data: Data) throws -> [GitHubPullRequest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubPullRequest].self, from: data)
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
        let checks = statusCheckRollup ?? []
        guard !checks.isEmpty else { return nil }
        let failed: Set = ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"]
        if checks.contains(where: { failed.contains($0.conclusion ?? "") || failed.contains($0.state ?? "") }) { return .failing }
        let running: Set = ["PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"]
        if checks.contains(where: { running.contains($0.status ?? "") || running.contains($0.state ?? "") }) { return .pending }
        return .passing
    }
}
