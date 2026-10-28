/// Partial updates must be merged with the current thread, not replace its other metadata.
enum AgentEvent: Sendable {
    case threadUpdated(sessionID: String, update: AgentThreadUpdate)
    case threadInvalidated(sessionID: String)
    case threadDeleted(sessionID: String)
    /// The thread's conversation gained or changed messages.
    case transcriptChanged(sessionID: String)
    case interactionRequested(AgentInteraction)
    case interactionResolved(id: String)
    case listInvalidated
}
