import SwiftUI

struct InputQuestionRow: View {
    let question: InputQuestion
    @Binding var draft: QuestionDraft

    var body: some View {
        VStack(alignment: .leading) {
            Text(question.header).font(.headline)
            Text(question.question)
            ForEach(question.options.enumerated(), id: \.offset) { index, option in
                Button {
                    draft.optionIndex = index
                    draft.text = ""
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: draft.optionIndex == index ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(option.label)
                            if !option.description.isEmpty { Text(option.description).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(draft.optionIndex == index ? .isSelected : [])
            }
            if question.allowsOther || question.options.isEmpty {
                if question.isSecret { SecureField("Your answer", text: $draft.text) }
                else { TextField(question.options.isEmpty ? "Your answer" : "Other answer", text: $draft.text, axis: .vertical) }
            }
        }
        .onChange(of: draft.text) { _, value in if !value.isEmpty { draft.optionIndex = nil } }
    }
}
