import Foundation

/// A pull request linked to a task, as the host last read it with `gh`.
nonisolated struct PullRequest: Codable, Sendable, Hashable, Identifiable {
    nonisolated enum State: String, Codable, Sendable {
        case open, draft, merged, closed
    }

    nonisolated enum Checks: String, Codable, Sendable {
        case passing, failing, pending
    }

    nonisolated enum Review: String, Codable, Sendable {
        case approved, changesRequested, required
    }

    var url: URL
    var number: Int
    var title: String
    /// `owner/name` of the repository it's in.
    var repository: String
    var branch: String
    var state: State
    /// Nil when the repository runs no checks on it.
    var checks: Checks?
    var review: Review?

    var id: URL { url }
}
