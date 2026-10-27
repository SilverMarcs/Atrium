import Foundation

/// A prompt sent from this phone that the task's transcript doesn't show yet,
/// drawn at the end of the timeline until it does.
struct PendingPrompt: Identifiable, Equatable {
    enum State: Equatable {
        case sending
        /// The host took it; it stays until the transcript shows it.
        case sent
        case failed
    }

    let id = UUID()
    let text: String
    /// Attached images, as the JPEG data sent to the host.
    var images: [Data] = []
    var state: State = .sending
    /// The newest user message in the transcript when this was sent.
    var anchorUserMessageID: String?
    /// How many user messages the transcript will hold after the anchor once
    /// it shows this prompt, which is how it's recognized there. Counting from
    /// the anchor rather than from the start keeps working once older
    /// messages drop out of the transcript's window, as they do on every new
    /// message in a long conversation.
    var expectedUserMessagesAfterAnchor: Int
    /// Sent a while ago to an agent still working, which hasn't taken it yet.
    /// It goes once the agent stops.
    var isOverdue = false

    /// Distinct from transcript message IDs, so the timeline can tell an
    /// optimistic row from a confirmed one.
    var timelineID: String { "pending-\(id.uuidString)" }
}
