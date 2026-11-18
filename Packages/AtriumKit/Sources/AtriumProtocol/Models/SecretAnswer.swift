import Foundation

/// How the user answered an agent's request for a secret.
public nonisolated enum SecretAnswer: Codable, Sendable, Hashable {
    /// The value is in this owner-only file, which the host deletes a day later.
    case saved(file: String)
    case declined
    /// No answer came in time, or the request was withdrawn.
    case timedOut
}
