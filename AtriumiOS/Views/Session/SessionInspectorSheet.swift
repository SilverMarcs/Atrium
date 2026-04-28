import SwiftUI

struct SessionInspectorSheet: View {
    @Environment(CompanionClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let workspaceId: UUID

    @State private var scratchpadDraft: String = ""
    @State private var hasLoadedScratchpad = false
    /// Coalesces typing in the scratchpad field. Avoids hitting the wire
    /// on every keystroke — pushes 400 ms after the last edit.
    @State private var pushTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                if let session = client.activeSession {
                    Section("Model") {
                        Label {
                            Text(session.modelLabel.isEmpty ? "—" : session.modelLabel)
                        } icon: {
                            Image(providerSymbol(for: session.meta.providerName))
                                .foregroundStyle(providerColor(for: session.meta.providerName))
                        }
                    }
                    Section("Permission") {
                        Label(
                            session.permissionLabel.isEmpty ? "—" : session.permissionLabel,
                            systemImage: session.permissionSystemImage.isEmpty
                                ? "lock"
                                : session.permissionSystemImage
                        )
                    }
                    Section("Context") {
                        ContextUsageRow(used: session.usedTokens, total: session.contextSize)
                    }
                }
                Section("Scratchpad") {
                    TextEditor(text: $scratchpadDraft)
                        .frame(minHeight: 180)
                        .onChange(of: scratchpadDraft) { _, newValue in
                            guard hasLoadedScratchpad else { return }
                            scheduleScratchpadPush(newValue)
                        }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Session info")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .task(id: workspaceId) {
            // Seed the editor with whatever the host last broadcast for
            // this workspace. The flag stops the onChange handler from
            // pushing back the seeded value.
            if let workspace = client.workspaces.first(where: { $0.id == workspaceId }) {
                scratchpadDraft = workspace.scratchpad
            }
            hasLoadedScratchpad = true
        }
        .onDisappear {
            pushTask?.cancel()
        }
    }

    /// Same provider-symbol mapping used elsewhere in the iOS app —
    /// matches the `model.imageName` value the macOS toolbar uses.
    private func providerSymbol(for providerName: String) -> String {
        switch providerName {
        case "Claude": return "claude.symbols"
        case "Codex": return "openai.symbols"
        case "Gemini": return "gemini.symbols"
        default: return "sparkles"
        }
    }

    /// Provider tint — same RGB values as `AgentProvider.color` on macOS.
    private func providerColor(for providerName: String) -> Color {
        switch providerName {
        case "Claude": return Color(red: 0.84, green: 0.41, blue: 0.23)
        case "Codex": return Color(red: 0.0, green: 0.58, blue: 0.48)
        case "Gemini": return Color(red: 0.26, green: 0.52, blue: 0.96)
        default: return .accentColor
        }
    }

    private func scheduleScratchpadPush(_ text: String) {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            client.updateScratchpad(workspaceId: workspaceId, text: text)
        }
    }
}
