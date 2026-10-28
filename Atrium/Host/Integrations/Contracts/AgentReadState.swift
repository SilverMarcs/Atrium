/// An opaque provider revision used to reconcile unread results across refreshes and events.
struct AgentReadState: Codable, Sendable, Equatable {
    let revision: String
    let isUnread: Bool
}
