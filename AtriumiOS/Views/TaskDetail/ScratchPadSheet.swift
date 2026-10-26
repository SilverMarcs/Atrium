import SwiftUI

/// The project's scratch pad, shared with the host's.
struct ScratchPadSheet: View {
    @Environment(CompanionClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let workspaceID: UUID

    @State private var text = ""
    @State private var hasLoaded = false
    @State private var lastSentText: String?
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .onChange(of: text) { _, text in
                    guard hasLoaded else { return }
                    scheduleSend(text)
                }
                .navigationTitle("Scratch Pad")
                .navigationSubtitle(client.workspace(workspaceID)?.name ?? "")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
        .task {
            text = client.workspace(workspaceID)?.scratchpad ?? ""
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
        client.send(.updateScratchpad(workspaceID: workspaceID, text: text))
        lastSentText = text
    }
}
