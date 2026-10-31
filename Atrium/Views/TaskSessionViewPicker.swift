import SwiftUI

/// Switches a session between its chat and its terminal.
struct TaskSessionViewPicker: View {
    @Binding var selection: String

    var body: some View {
        Picker("Session View", selection: $selection) {
            Label("Chat", systemImage: "bubble.left").tag("chat")
            Label("Terminal", systemImage: "terminal").tag("terminal")
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
    }
}
