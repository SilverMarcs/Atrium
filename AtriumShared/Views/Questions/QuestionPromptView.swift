import SwiftUI

struct QuestionPromptView: View {
    let prompt: QuestionPromptData
    let onSubmit: ([String: [String]]) -> Void
    @State private var drafts: [String: QuestionDraft] = [:]

    private var complete: Bool { prompt.questions.allSatisfy { drafts[$0.id]?.answer(for: $0) != nil } }

    var body: some View {
        VStack(alignment: .leading) {
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(prompt.questions) { question in
                        InputQuestionRow(question: question, draft: Binding(get: { drafts[question.id] ?? QuestionDraft() }, set: { drafts[question.id] = $0 }))
                        if question.id != prompt.questions.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 300)
            HStack {
                Button("Skip") { onSubmit([:]) }
                Spacer()
                Button("Submit Answers") {
                    let answers = Dictionary(uniqueKeysWithValues: prompt.questions.map { ($0.id, [drafts[$0.id]?.answer(for: $0) ?? ""]) })
                    onSubmit(answers)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!complete)
            }
        }
        .padding()
    }
}
