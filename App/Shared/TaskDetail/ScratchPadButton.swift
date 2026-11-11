import SwiftUI

/// Opens the task's project scratch pad.
struct ScratchPadButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button("Scratch Pad", systemImage: "note.text") { isPresented = true }
        #if os(macOS)
        .keyboardShortcut(".")
        #endif
    }
}
