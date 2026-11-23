import Foundation

/// A pull request linked to a task, as the host last read it with `gh`.
public nonisolated struct PullRequest: Codable, Sendable, Hashable, Identifiable {
    public nonisolated enum State: String, Codable, Sendable {
        case open, draft, merged, closed
    }

    public nonisolated enum Checks: String, Codable, Sendable {
        case passing, failing, pending
    }

    public nonisolated enum Review: String, Codable, Sendable {
        case approved, changesRequested, required
    }

    public var url: URL
    public var number: Int
    public var title: String
    /// `owner/name` of the repository it's in.
    public var repository: String
    public var branch: String
    public var state: State
    /// Nil when the repository runs no checks on it.
    public var checks: Checks?
    public var review: Review?

    public var id: URL { url }

    public init(
        url: URL, number: Int, title: String, repository: String, branch: String,
        state: State, checks: Checks? = nil, review: Review? = nil
    ) {
        self.url = url
        self.number = number
        self.title = title
        self.repository = repository
        self.branch = branch
        self.state = state
        self.checks = checks
        self.review = review
    }
}
