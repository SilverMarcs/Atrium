import Foundation

/// An HTML page an agent showed in its reply, such as a chart or a mockup.
/// Fetch it with `HostRequest.page(key:)`.
public nonisolated struct TranscriptPage: Codable, Sendable, Hashable {
    /// Names the page's content, so the same page sent twice shares it.
    public var key: String
    public var title: String
    /// The height the agent expects, in points, until the page measures itself.
    public var height: Int?

    public init(key: String, title: String, height: Int? = nil) {
        self.key = key
        self.title = title
        self.height = height
    }
}
