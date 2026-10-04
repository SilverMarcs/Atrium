import Foundation

public struct QuestionPromptData: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let questions: [InputQuestion]

    public init(id: UUID = UUID(), questions: [InputQuestion]) {
        self.id = id
        self.questions = questions
    }
}
