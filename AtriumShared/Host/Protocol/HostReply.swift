import Foundation

nonisolated enum HostReply: Codable, Sendable {
    case done
    case failed(message: String)
    case paired(token: String)
    /// The task a compose or fork created.
    case task(id: String)
    case workspace(id: UUID)
    case command(id: UUID)
    case icon(data: Data)
    case git(GitReply)
    case files(FileReply)
    /// A reply this client doesn't know, from a newer host.
    case unknown

    static let unsupported = HostReply.failed(message: "Your host doesn’t support this. Update Atrium on it.")
    static let hostOnly = HostReply.failed(message: "This can only be done on the host itself.")
}
