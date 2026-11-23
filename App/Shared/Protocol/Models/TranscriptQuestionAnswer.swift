import Foundation

/// A user's answer to a question the agent asked in the conversation.
nonisolated struct TranscriptQuestionAnswer: Codable, Sendable, Hashable {
    var question: String
    var answer: String
}
