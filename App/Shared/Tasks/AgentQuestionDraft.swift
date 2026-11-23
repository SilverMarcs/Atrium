import Foundation

nonisolated struct AgentQuestionDraft: Identifiable {
    let question: AgentQuestion
    var selections: Set<String> = []
    var text = ""
    init(question: AgentQuestion) {
        self.question = question
        selections = !question.allowsMultiple ? Set(question.options.prefix(1)) : []
    }

    var id: String { question.id }
    var answers: [String] {
        let other = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return question.options.filter { selections.contains($0) } + (other.isEmpty ? [] : [other])
    }
}
