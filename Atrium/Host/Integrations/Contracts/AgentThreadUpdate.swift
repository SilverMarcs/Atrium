import Foundation

struct AgentThreadUpdate: Sendable {
    var status: AgentThreadStatus?
    var readState: AgentReadState?
    var title: String?
    var updatedAt: Date?
    var startsNewTurn = false

    func applying(to source: AgentThread) -> AgentThread {
        var thread = source
        if let status { thread.status = status }
        if let readState { thread.readState = readState }
        if let title {
            thread.title = title
            thread.hasProviderTitle = true
        }
        if let updatedAt { thread.updatedAt = updatedAt }
        return thread
    }
}
