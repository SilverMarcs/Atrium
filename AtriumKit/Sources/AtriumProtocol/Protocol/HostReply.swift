import Foundation

public nonisolated enum HostReply: Codable, Sendable {
    case done
    /// Canonical retained history and the original prompt attachments, ready to resend.
    case rewound(messages: [TranscriptMessage], images: [Data])
    case failed(message: String)
    case paired(token: String)
    /// The task a compose or fork created.
    case task(id: String)
    case workspace(id: UUID)
    case command(id: UUID)
    case icon(data: Data)
    case page(html: String)
    case git(GitReply)
    case files(FileReply)
    /// A reply this client doesn't know, from a newer host.
    case unknown

    public static let unsupported = HostReply.failed(message: "Your host doesn’t support this. Update Atrium on it.")
    public static let hostOnly = HostReply.failed(message: "This can only be done on the host itself.")
}
