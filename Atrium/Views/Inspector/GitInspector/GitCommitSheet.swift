import SwiftUI

struct GitCommitSheet: View {
    @Binding var message: String
    @Binding var isPresented: Bool
    var onCommit: (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Commit Staged Changes")
                .font(.headline)

            TextEditor(text: $message)
                .font(.body.monospaced())
                .frame(minHeight: 80, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Commit") {
                    let msg = message
                    isPresented = false
                    onCommit(msg)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
