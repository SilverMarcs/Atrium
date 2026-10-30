import SwiftUI
import UniformTypeIdentifiers

/// Makes the conversation and its composer one attachment drop region.
struct ComposerDropHandler: ViewModifier {
    var isEnabled = true
    let receive: @MainActor (ComposerPasteContent) throws -> Void
    @State private var importError: String?

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.image, .fileURL], isTargeted: nil, perform: handleDrop)
            .alert("Couldn’t Attach Item", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard isEnabled else { return false }
        let transfers = providers.compactMap { ComposerPasteContent.beginLoading(from: $0) }
        guard !transfers.isEmpty else { return false }
        Task {
            // All provider requests have started; apply results in drop order.
            for transfer in transfers {
                do {
                    if let attachment = try await transfer.value {
                        try receive(attachment)
                    }
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        return true
    }
}

extension View {
    /// Drops into the composer's draft. A drop that lands after the edit it
    /// started over has been submitted or cancelled is discarded.
    func composerDropHandler(_ composer: TaskComposer, isEnabled: Bool = true) -> some View {
        let editing = composer.messageEdit
        return modifier(ComposerDropHandler(isEnabled: isEnabled && editing?.isSubmitting != true) { content in
            guard composer.messageEdit === editing, editing?.isSubmitting != true else { return }
            try composer.receive(content)
        })
    }
}
