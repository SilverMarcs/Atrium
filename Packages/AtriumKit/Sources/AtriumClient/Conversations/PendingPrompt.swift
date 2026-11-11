import Foundation

/// A prompt sent from this device that the task's transcript doesn't show yet,
/// drawn at the end of the timeline until it does.
public nonisolated struct PendingPrompt: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case sending
        /// The host took it; it stays until the transcript shows it.
        case sent
        case failed
    }

    /// Also the prompt's key, so retrying it can't prompt the agent twice.
    public let id = UUID()
    public let text: String
    /// Attached images, as the JPEG data sent to the host.
    public var images: [Data] = []
    public var state: State = .sending
    public var failureMessage: String?
    /// The newest user message in the transcript when this was sent.
    public var anchorUserMessageID: String?
    /// How many user messages the transcript will hold after the anchor once
    /// it shows this prompt, which is how it's recognized there. Counting from
    /// the anchor rather than from the start keeps working once older
    /// messages drop out of the transcript's window, as they do on every new
    /// message in a long conversation.
    public var expectedUserMessagesAfterAnchor: Int
    /// Sent a while ago to an agent still working, which hasn't taken it yet.
    /// It goes once the agent stops.
    public var isOverdue = false
    /// Sent while the agent was working, so it joins that turn.
    public var isSteer = false

    /// Distinct from transcript message IDs, so the timeline can tell an
    /// optimistic row from a confirmed one.
    public var timelineID: String { "pending-\(id.uuidString)" }
}
