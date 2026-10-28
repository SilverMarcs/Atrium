import SwiftUI

/// A project's scratch pad, kept on its host and shared by every client.
struct ScratchPadSheet: View {
    let host: HostClient
    let workspaceID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var hasLoaded = false
    @State private var lastSentText: String?
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                #if os(iOS)
                .contentMargins(.horizontal, 16, for: .scrollContent)
                #else
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                #endif
                .onChange(of: text) { _, text in
                    guard hasLoaded else { return }
                    scheduleSend(text)
                }
                .navigationTitle("Scratch Pad")
                .navigationSubtitle(host.workspace(workspaceID)?.name ?? "")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", role: .close) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        #if os(macOS)
        .frame(width: 500, height: 400)
        #endif
        .task {
            text = host.workspace(workspaceID)?.scratchpad ?? ""
            lastSentText = text
            hasLoaded = true
        }
        .onDisappear {
            sendTask?.cancel()
            if hasLoaded { flush(text) }
        }
    }

    /// Typing is coalesced so the host isn't updated on every keystroke.
    private func scheduleSend(_ text: String) {
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            flush(text)
        }
    }

    private func flush(_ text: String) {
        guard text != lastSentText else { return }
        host.send(.workspace(id: workspaceID, action: .setScratchpad(text)))
        lastSentText = text
    }
}
