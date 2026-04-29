import SwiftUI

struct SessionInspectorSheet: View {
    @Environment(CompanionClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let workspaceId: UUID

    @State private var scratchpadDraft: String = ""
    @State private var hasLoadedScratchpad = false
    /// Last text we successfully pushed to the host. Used to dedupe pushes
    /// (the seed value and unchanged dismissals shouldn't re-send).
    @State private var lastPushedText: String?
    /// Coalesces typing in the scratchpad field. Avoids hitting the wire
    /// on every keystroke — pushes 400 ms after the last edit.
    @State private var pushTask: Task<Void, Never>?

    /// Selection drives the host via `setSessionModel`; `CompanionClient`
    /// optimistically updates `activeSession` so the picker doesn't lag.
    private var modelBinding: Binding<String> {
        Binding(
            get: { client.activeSession?.modelRawValue ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                client.setSessionModel(newValue)
            }
        )
    }

    private var permissionBinding: Binding<String> {
        Binding(
            get: { client.activeSession?.permissionModeRawValue ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                client.setSessionPermissionMode(newValue)
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if let session = client.activeSession {
                    Section("Model") {
                        Picker(selection: modelBinding) {
                            ForEach(session.availableModels) { model in
                                Label {
                                    Text(model.name)
                                } icon: {
                                    Image(model.imageName)
                                        .foregroundStyle(ProviderStyle.color(forProviderName: session.meta.providerName))
                                }
                                .tag(model.rawValue)
                            }
                        } label: {
                            Label {
                                Text(session.meta.providerName)
                            } icon: {
                                // Image(ProviderStyle.symbolName(forProviderName: session.meta.providerName))
                                    // .foregroundStyle(ProviderStyle.color(forProviderName: session.meta.providerName))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    
                    Section("Permission") {
                        Picker(selection: permissionBinding) {
                            ForEach(session.availableModes) { mode in
                                Label(mode.label, systemImage: mode.systemImage)
                                    .tag(mode.rawValue)
                                    .labelStyle(.iconOnly)
                            }
                        } label: {
                            Label(
                                session.permissionLabel.isEmpty ? "—" : session.permissionLabel,
                                systemImage: session.permissionSystemImage.isEmpty
                                    ? "lock"
                                    : session.permissionSystemImage
                            )
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, -16)
                        .padding(.top, -13)
                    }
                    .controlSize(.large)
                    // .listSectionMargins(.horizontal, 0)
                    .listSectionSpacing(.compact)
                    .listSectionSeparator(.hidden)
                    .listRowBackground(Color.clear)

                    
                    Section("Context") {
                        ContextUsageRow(used: session.usedTokens, total: session.contextSize)
                    }
                }
                Section("Scratchpad") {
                    TextField("Enter your thoughts", text: $scratchpadDraft, axis: .vertical)
                        .lineLimit(8, reservesSpace: true)
                        .labelsHidden()
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
                lastPushedText = workspace.scratchpad
            }
            hasLoadedScratchpad = true
        }
        .onDisappear {
            pushTask?.cancel()
            pushTask = nil
            // Cancellation alone would drop a pending edit on the floor —
            // flush whatever the user typed so the Mac always gets the
            // final value when they close the sheet.
            if hasLoadedScratchpad {
                flushScratchpad(scratchpadDraft)
            }
        }
    }

    private func scheduleScratchpadPush(_ text: String) {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            flushScratchpad(text)
        }
    }

    private func flushScratchpad(_ text: String) {
        guard lastPushedText != text else { return }
        client.updateScratchpad(workspaceId: workspaceId, text: text)
        lastPushedText = text
    }
}
