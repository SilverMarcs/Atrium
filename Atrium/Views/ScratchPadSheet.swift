import SwiftUI

struct ScratchPadSheet: View {
    @Bindable var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $workspace.scratchPad)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .navigationTitle("Scratch Pad")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .frame(width: 500, height: 400)
    }
}
