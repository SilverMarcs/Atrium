import AtriumProtocol
import Foundation

/// Codex may record a question-sheet reply as tagged JSON, or as the prompt
/// Atrium sent when the user answered its asynchronous question.
nonisolated enum CodexQuestionReply {
    private struct TaggedAnswer: Decodable {
        let question: String
        let answer: String
    }

    static func answers(in text: String, to questions: [AgentQuestion]) -> [TranscriptQuestionAnswer]? {
        let opening = "<send_user_message_question_reply>"
        let closing = "</send_user_message_question_reply>"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(opening), trimmed.hasSuffix(closing) {
            let json = trimmed.dropFirst(opening.count).dropLast(closing.count)
            guard let tagged = try? JSONDecoder().decode([TaggedAnswer].self, from: Data(json.utf8)),
                  !tagged.isEmpty, tagged.allSatisfy({ !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
            return tagged.map { TranscriptQuestionAnswer(question: $0.question, answer: $0.answer) }
        }

        guard !questions.isEmpty else { return nil }
        var remaining = text[...]
        var answers: [TranscriptQuestionAnswer] = []
        for (index, question) in questions.enumerated() {
            let prefix = question.title + "\n"
            guard remaining.hasPrefix(prefix) else { return nil }
            remaining.removeFirst(prefix.count)
            let answer: String
            if index + 1 < questions.count {
                let next = "\n\n" + questions[index + 1].title + "\n"
                guard let boundary = remaining.range(of: next) else { return nil }
                answer = String(remaining[..<boundary.lowerBound])
                remaining = remaining[boundary.lowerBound...].dropFirst(2)
            } else {
                answer = String(remaining)
            }
            answers.append(TranscriptQuestionAnswer(question: question.title, answer: answer))
        }
        return answers
    }
}
