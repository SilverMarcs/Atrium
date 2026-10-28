import SwiftUI

/// One native decision form for the host and companion.
struct AgentInteractionSheet: View {
    let request: AgentInteraction
    let respond: (AgentDecision) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [AgentQuestionDraft]
    @State private var isResponding = false
    @State private var error: String?

    init(request: AgentInteraction, respond: @escaping (AgentDecision) async throws -> Void) {
        self.request = request
        self.respond = respond
        _drafts = State(initialValue: request.questions.map { AgentQuestionDraft(question: $0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                if request.questions.isEmpty, !request.detail.isEmpty {
                    Section { Text(request.detail).textSelection(.enabled) }
                }
                ForEach($drafts) { $draft in
                    Section(draft.question.title) {
                        if draft.question.allowsMultiple {
                            ForEach(draft.question.options, id: \.self) { option in
                                Toggle(isOn: Binding(
                                    get: { draft.selections.contains(option) },
                                    set: { selected in
                                        if selected { draft.selections.insert(option) }
                                        else { draft.selections.remove(option) }
                                    }
                                )) {
                                    Text(option)
                                    if let description = draft.question.optionDescriptions[option]?.trimmingCharacters(in: .whitespacesAndNewlines),
                                       !description.isEmpty, description != option.trimmingCharacters(in: .whitespacesAndNewlines) {
                                        Text(description)
                                    }
                                }
                            }
                        } else if !draft.question.options.isEmpty {
                            Picker(selection: Binding(
                                get: { draft.selections.first ?? "" },
                                set: { value in
                                    draft.selections = value.isEmpty ? [] : [value]
                                    if !value.isEmpty { draft.text = "" }
                                }
                            )) {
                                ForEach(draft.question.options, id: \.self) { option in
                                    LabeledContent {} label: {
                                        Text(option)
                                        if let description = draft.question.optionDescriptions[option]?.trimmingCharacters(in: .whitespacesAndNewlines),
                                       !description.isEmpty, description != option.trimmingCharacters(in: .whitespacesAndNewlines) {
                                            Text(description)
                                        }
                                    }
                                    .tag(option)
                                }
                            }
                            label: { EmptyView() }
                            .accessibilityLabel("Answer")
                            #if os(macOS)
                            .pickerStyle(.radioGroup)
                            #else
                            .pickerStyle(.inline)
                            #endif
                        }
                        if draft.question.isSecret {
                            SecureField("Your answer", text: $draft.text)
                        } else {
                            TextField(draft.question.options.isEmpty ? "Your answer" : "Another answer", text: $draft.text, axis: .vertical)
                                .onChange(of: draft.text) {
                                    if !draft.question.allowsMultiple, !draft.text.isEmpty { draft.selections.removeAll() }
                                }
                        }
                    }
                }

            }
            .formStyle(.grouped)
            .navigationTitle(request.title)
            .toolbar {
                if request.supportsResponse {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Decline", role: .destructive) { submit(AgentDecision(allowed: false)) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(drafts.isEmpty ? "Allow" : "Submit") {
                            submit(AgentDecision(allowed: true, answers: Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0.answers) })))
                        }
                        .disabled(!drafts.allSatisfy { !$0.answers.isEmpty })
                    }
                }
                if !request.supportsResponse {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                if isResponding {
                    ToolbarItem { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isResponding)
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 520, minHeight: 300, idealHeight: 440)
        #else
        .presentationDetents([.medium, .large])
        #endif
        .interactiveDismissDisabled(request.supportsResponse || isResponding)
        .alert("Couldn’t Send Response", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func submit(_ decision: AgentDecision) {
        guard !isResponding else { return }
        isResponding = true
        Task {
            defer { isResponding = false }
            do { try await respond(decision); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
