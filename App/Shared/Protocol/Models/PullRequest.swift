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

    /// Where its repository is checked out on the host.
    nonisolated struct Local: Codable, Sendable, Hashable {
        /// Root of the repository's main checkout.
        var repository: URL
        /// The remote that is its GitHub repository, e.g. "origin".
        var remote: String
    }

    var url: URL
    var number: Int
    var title: String
    /// `owner/name` of the repository it's in.
    var repository: String
    var branch: String
    /// The branch it merges into, e.g. "main"; nil until it's read again
    /// after an update that saved it without one.
    var base: String?
    var state: State
    /// Nil when the repository runs no checks on it.
    var checks: Checks?
    var review: Review?
    /// Nil when none of its task's checkouts pushes to its repository.
    var local: Local?

    var id: URL { url }
}
