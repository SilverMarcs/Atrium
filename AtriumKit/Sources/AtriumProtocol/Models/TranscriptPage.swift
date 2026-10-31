import Foundation

/// An HTML page an agent showed in its reply, such as a chart or a mockup.
/// Fetch it with `HostRequest.page(taskID:key:)`.
public nonisolated struct TranscriptPage: Codable, Sendable, Hashable {
    /// Names the page's content, so the same page sent twice shares it. Nil
    /// while the agent is still writing the page.
    public var key: String?
    public var title: String

    public init(key: String?, title: String) {
        self.key = key
        self.title = title
    }
}
