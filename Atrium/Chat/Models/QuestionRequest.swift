import Foundation
import Observation

@Observable
@MainActor
final class QuestionRequest: Identifiable {
    let prompt: QuestionPromptData
    let requiresActiveTurn: Bool
    private var reply: (([String: [String]]) -> Void)?

    nonisolated var id: UUID { prompt.id }

    init(questions: [InputQuestion], requiresActiveTurn: Bool = true, reply: @escaping ([String: [String]]) -> Void) {
        prompt = QuestionPromptData(questions: questions)
        self.requiresActiveTurn = requiresActiveTurn
        self.reply = reply
    }

    @discardableResult
    func respond(_ answers: [String: [String]]) -> Bool {
        guard let action = reply, answers.keys.allSatisfy({ id in prompt.questions.contains { $0.id == id } }) else { return false }
        for question in prompt.questions {
            let values = answers[question.id] ?? []
            guard values.count <= 1 else { return false }
            if let value = values.first, !question.allowsOther, !question.options.isEmpty,
               !question.options.contains(where: { $0.label == value }) { return false }
        }
        reply = nil
        action(answers)
        return true
    }
}
