import SwiftUI

/// Opens the task's project scratchpad.
struct ScratchpadButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button("Scratchpad", systemImage: "note.text") { isPresented = true }
        #if os(macOS)
        .keyboardShortcut(".")
        #endif
    }
}
