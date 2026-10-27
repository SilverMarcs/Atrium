import SwiftUI

/// A new task's empty timeline, where the agent the host creates it with is
/// chosen before the first prompt is sent.
struct DraftAgentPicker: View {
    @Environment(CompanionClient.self) private var client
    let draft: TaskDraft

    private var providers: [AgentProvider] {
        client.tasks?.providers.filter(\.isEnabled).map(\.provider) ?? []
    }

    var body: some View {
        if providers.isEmpty {
            ContentUnavailableView(
                "No Agents Enabled",
                systemImage: "sparkles",
                description: Text("Turn on Codex or Claude in Atrium’s settings on your host.")
            )
        } else {
            ContentUnavailableView {
                Label {
                    Text(draft.provider.name)
                } icon: {
                    ProviderIcon(provider: draft.provider)
                        .contentTransition(.symbolEffect(.replace))
                }
            } description: {
                if let workspace = client.workspace(draft.workspaceID) {
                    Text("New task in \(workspace.name)")
                }
            } actions: {
                if providers.count > 1 {
                    Picker("Agent", selection: Binding(
                        get: { draft.provider },
                        set: { client.setProvider($0, ofDraft: draft.id) }
                    ).animation()) {
                        ForEach(providers) { provider in
                            Text(provider.name)
                                .tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
    }
}
