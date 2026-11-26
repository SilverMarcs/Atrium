import Foundation

nonisolated enum HostReply: Codable, Sendable {
    case done
    /// Canonical retained history and the original prompt attachments, ready to resend.
    case rewound(messages: [TranscriptMessage], images: [Data])
    case failed(message: String)
    case paired(token: String)
    /// The task a compose or side chat created.
    case task(id: String)
    case skills([AgentSkill])
    /// The task a fork created, with the original images of the prompt it
    /// was forked before, so a client can put that prompt in its composer.
    case forked(taskID: String, images: [Data])
    /// A prompt taken back for the composer, with its images as they were
    /// sent: from a task's queue, to edit or because its turn was stopped, or
    /// from a project's scratchpad.
    case queuedPrompt(text: String, images: [Data])
    case workspace(id: UUID)
    case command(id: UUID)
    case icon(data: Data)
    case page(html: String)
    /// Encoded image data, in the file's own format when it's one clients show.
    case image(data: Data)
    case previewSources([LivePreviewSource])
    case previewOffer(sdp: String, iceServers: [PreviewICEServer])
    case git(GitReply)
    case files(FileReply)
    /// The host's MCP reply to a `.mcp` message, empty for a notification.
    case mcp(message: Data)
    /// A reply this client doesn't know, from a newer host.
    case unknown

    static let unsupported = HostReply.failed(message: "Your host doesn’t support this. Update Diffs on it.")
    static let hostOnly = HostReply.failed(message: "This can only be done on the host itself.")
}
