import Foundation

public struct InputQuestion: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let header: String
    public let question: String
    public let options: [InputQuestionOption]
    public let allowsOther: Bool
    public let isSecret: Bool

    public init(id: String, header: String, question: String, options: [InputQuestionOption], allowsOther: Bool, isSecret: Bool) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.allowsOther = allowsOther
        self.isSecret = isSecret
    }
}
