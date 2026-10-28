import SwiftUI

struct CommandEntrySheet: View {
    let project: Project
    var command: WireCommand?

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
                    .font(.body.monospaced())
                    .labelsHidden()
            }
            .formStyle(.grouped)
            .navigationTitle(command == nil ? "New Command" : "Edit Command")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(command == nil ? "Add" : "Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .onAppear {
            if let command {
                name = command.title
                script = command.script ?? ""
            }
        }
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespaces)
        let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let command {
            project.send(.update(title: name, script: script.isEmpty ? nil : script), to: command)
        } else {
            project.send(.addCommand(title: name, script: script.isEmpty ? nil : script))
        }
    }
}
