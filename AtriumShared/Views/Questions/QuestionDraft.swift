import Foundation

struct QuestionDraft {
    var optionIndex: Int?
    var text = ""

    func answer(for question: InputQuestion) -> String? {
        if let index = optionIndex, question.options.indices.contains(index) { return question.options[index].label }
        let value = question.isSecret ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
