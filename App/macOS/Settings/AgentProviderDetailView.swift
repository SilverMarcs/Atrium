import SwiftUI

/// Dedicated detail view for one agent provider, pushed from `AgentsSettingsView`.
struct AgentProviderDetailView: View {
    let provider: AgentProvider
    let isAvailable: Bool
    let usage: AgentUsageModel
    @Bindable var updates: AgentCLIUpdateModel
    let globalAgents: GlobalAgentsStore
    let onRefresh: () -> Void

    var body: some View {
        Form {
            accountSection
            sharedLinksSection
        }
        .formStyle(.grouped)
        .navigationTitle(provider.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh \(provider.name) usage, CLI version, and symlinks")
            }
        }
        .alert("Couldn’t Update \(provider.name)", isPresented: $updates.showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(updates.errorMessage)
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        if isAvailable {
            Section {
                LabeledContent("Status", value: usage.snapshot.status)
                if let plan = usage.snapshot.plan {
                    LabeledContent("Plan", value: plan)
                }
                if usage.snapshot.windows.isEmpty {
                    LabeledContent("Usage", value: usage.snapshot.usageMessage ?? "Unavailable")
                } else {
                    ForEach(usage.snapshot.windows) { window in
                        LabeledContent(window.title) {
                            VStack(alignment: .trailing) {
                                Text("\((window.usedPercent / 100).formatted(.percent.precision(.fractionLength(0)))) used")
                                if let reset = window.resetsAt {
                                    Text("Resets \(reset.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Account & Usage")
            } footer: {
                HStack {
                    Text(updates.status)
                    Spacer()
                    Button(updates.buttonTitle, action: update)
                        .disabled(updates.isDisabled)
                }
            }
        } else {
            Section {
                LabeledContent("Status", value: "Not installed")
            } header: {
                Text("Installation")
            } footer: {
                HStack {
                    Text("Atrium finds \(provider.name) on its own once it’s installed.")
                    Spacer()
                    Link("Installation Guide", destination: provider.installationGuide)
                }
            }
        }
    }

    @ViewBuilder
    private var sharedLinksSection: some View {
        if let group = globalAgents.linkGroup(for: provider) {
            Section {
                ProviderLinkRow(store: globalAgents, provider: provider, target: group.instructions)
                ProviderLinkRow(store: globalAgents, provider: provider, target: group.skills)
            } header: {
                Text("Shared Rules & Skills")
            } footer: {
                Text("Symlink \(provider.name) to ~/.agents so it shares your global AGENTS.md and skills.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func update() {
        Task { await updates.performAction(provider) }
    }
}

private extension AgentProvider {
    var installationGuide: URL {
        switch self {
        case .codex: URL(string: "https://developers.openai.com/codex/cli")!
        case .claude: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!
        case .antigravity: URL(string: "https://antigravity.google/product/antigravity-cli")!
        }
    }
}
