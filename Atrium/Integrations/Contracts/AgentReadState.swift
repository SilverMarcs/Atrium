/// An opaque provider revision used to reconcile unread results across refreshes and events.
struct AgentReadState: Sendable, Equatable {
    let revision: String
    let isUnread: Bool
}
