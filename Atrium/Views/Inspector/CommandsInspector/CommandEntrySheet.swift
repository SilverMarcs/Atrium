import SwiftUI

struct CommandEntrySheet: View {
    let workspace: Workspace
    var terminal: Terminal?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var script = ""

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)

                TextField("Script", text: $script, axis: .vertical)
                    .lineLimit(5, reservesSpace: true)
                    .font(.system(.body, design: .monospaced))
                    .labelsHidden()
            }
            .formStyle(.grouped)
            .navigationTitle(terminal == nil ? "New Command" : "Edit Command")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(terminal == nil ? "Add" : "Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .onAppear {
            if let terminal {
                name = terminal.title
                script = terminal.runScript ?? ""
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        if let terminal {
            terminal.title = trimmedName
            terminal.runScript = trimmedScript.isEmpty ? nil : trimmedScript
        } else {
            workspace.addCommand(
                title: trimmedName,
                runScript: trimmedScript.isEmpty ? nil : trimmedScript
            )
        }
    }
}
