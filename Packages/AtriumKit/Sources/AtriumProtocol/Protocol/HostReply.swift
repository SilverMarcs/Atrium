import Foundation

public nonisolated enum HostReply: Codable, Sendable {
    case done
    /// Canonical retained history and the original prompt attachments, ready to resend.
    case rewound(messages: [TranscriptMessage], images: [Data])
    case failed(message: String)
    case paired(token: String)
    /// The hosts a Mac's app paired its command-line client with.
    case sharedHosts([SharedHost])
    /// The task a compose or side chat created, or the session a caller runs in.
    case task(id: String)
    /// The task a fork created, with the original images of the prompt it
    /// was forked before, so a client can put that prompt in its composer.
    case forked(taskID: String, images: [Data])
    /// The prompt taken back from a task's queue, to edit or because its turn
    /// was stopped, with its images as they were sent.
    case queuedPrompt(text: String, images: [Data])
    case workspace(id: UUID)
    case command(id: UUID)
    case icon(data: Data)
    case page(html: String)
    /// Encoded image data, in the file's own format when it's one clients show.
    case image(data: Data)
    case git(GitReply)
    case files(FileReply)
    /// A reply this client doesn't know, from a newer host.
    case unknown

    public static let unsupported = HostReply.failed(message: "Your host doesn’t support this. Update Atrium on it.")
    public static let hostOnly = HostReply.failed(message: "This can only be done on the host itself.")
}
