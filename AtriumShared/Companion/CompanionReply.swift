import Foundation

nonisolated enum CompanionReply: Codable, Sendable {
    case done
    case failed(message: String)
    case paired(token: String)
    /// The task a compose or fork created.
    case task(id: String)
    case icon(data: Data)
    /// Raw `git diff` output; the companion parses hunks itself.
    case diff(text: String)
}
