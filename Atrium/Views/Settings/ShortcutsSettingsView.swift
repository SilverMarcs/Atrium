import SwiftUI

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Close Tab", value: "⌘ W")
                LabeledContent("Go to File", value: "⌘ P")
                LabeledContent("Find in Files", value: "⇧⌘ F")
            }

            Section("Chat") {
                LabeledContent("New Chat", value: "⌘ N")
                LabeledContent("Focus Input", value: "⌘ L")
                LabeledContent("Paste Text & Images", value: "⌘ V")
                LabeledContent("Send Message", value: "⌘ ⏎")
                LabeledContent("Stop Streaming", value: "⌘ D")
            }

            Section("View") {
                // LabeledContent("Zoom In", value: "⌘ +")
                // LabeledContent("Zoom Out", value: "⌘ -")
                // LabeledContent("Actual Size", value: "⌘ 0")
                LabeledContent("Toggle Editor Panel", value: "⌘ J")
                LabeledContent("Show/Hide Hidden Files", value: "⇧⌘ .")
            }

            Section("Inspector") {
                LabeledContent("Files Navigator", value: "⌘ 1")
                LabeledContent("Git Navigator", value: "⌘ 2")
                LabeledContent("Search Navigator", value: "⌘ 3")
                LabeledContent("Command Runner", value: "⌘ 4")
            }

            Section("Commands") {
                LabeledContent("Run Default Command", value: "⌘ R")
                LabeledContent("Stop Default Command", value: "⌘ D")
            }

            Section("Editor") {
                LabeledContent("Save File", value: "⌘ S")
                LabeledContent("Show in File Tree", value: "⇧⌘ J")
            }
        }
        .formStyle(.grouped)
        .labeledContentStyle(ShortcutLabeledContentStyle())
    }
}

private struct ShortcutLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            configuration.content
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
        }
    }
}

#Preview {
    ShortcutsSettingsView()
        .frame(width: 480)
}
