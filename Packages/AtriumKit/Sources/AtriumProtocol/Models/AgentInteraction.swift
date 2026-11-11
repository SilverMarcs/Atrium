import Foundation

/// A pending agent decision. The provider retains the context needed to send its answer.
public nonisolated struct AgentInteraction: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var taskID: String
    public var title: String
    public var detail: String
    public var questions: [AgentQuestion] = []
    public var supportsResponse: Bool = true

    public init(
        id: String,
        taskID: String,
        title: String,
        detail: String,
        questions: [AgentQuestion] = [],
        supportsResponse: Bool = true
    ) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.detail = detail
        self.questions = questions
        self.supportsResponse = supportsResponse
    }
}
