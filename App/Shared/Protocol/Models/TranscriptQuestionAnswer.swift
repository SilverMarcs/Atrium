import Foundation

/// A user's answer to a question the agent asked in the conversation.
public nonisolated struct TranscriptQuestionAnswer: Codable, Sendable, Hashable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}
