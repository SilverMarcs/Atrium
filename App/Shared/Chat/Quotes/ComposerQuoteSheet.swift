import SwiftUI

/// Writes the reply to a quoted passage, laid out like an agent's question:
/// the passage above, the reply below.
struct ComposerQuoteSheet: View {
    let isNew: Bool
    let save: (ComposerQuote) -> Void
    @State private var quote: ComposerQuote
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isReplyFocused: Bool

    init(quote: ComposerQuote, isNew: Bool, save: @escaping (ComposerQuote) -> Void) {
        self.isNew = isNew
        self.save = save
        _quote = State(initialValue: quote)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your reply", text: $quote.reply, prompt: Text("Your reply"), axis: .vertical)
                        .focused($isReplyFocused)
                        #if os(macOS)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #endif
                } header: {
                    Text(quote.text)
                        .textCase(nil)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Quote")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Done", systemImage: isNew ? "plus" : "checkmark", role: .confirm) {
                        save(quote)
                        dismiss()
                    }
                    #if os(iOS)
                    .labelStyle(.iconOnly)
                    #endif
                }
            }
            .onAppear { isReplyFocused = true }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 520, minHeight: 300, idealHeight: 440)
        #endif
    }
}
