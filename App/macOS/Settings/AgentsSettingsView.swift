import Observation
import SwiftUI

/// Caches per-provider usage and CLI update models across overview ↔ detail navigation
/// so pushing into a provider doesn't re-fetch or flash "Loading…".
@MainActor
@Observable
final class AgentProviderModels {
    private var usageByProvider: [AgentProvider: AgentUsageModel] = [:]
    private var updatesByProvider: [AgentProvider: AgentCLIUpdateModel] = [:]

    func usage(for provider: AgentProvider) -> AgentUsageModel {
        if let existing = usageByProvider[provider] { return existing }
        let created = AgentUsageModel()
        usageByProvider[provider] = created
        return created
    }

    func updates(for provider: AgentProvider) -> AgentCLIUpdateModel {
        if let existing = updatesByProvider[provider] { return existing }
        let created = AgentCLIUpdateModel()
        updatesByProvider[provider] = created
        return created
    }

    func refresh(_ provider: AgentProvider, read: (AgentProvider) async throws -> AgentUsageSnapshot) async {
        let usageModel = usage(for: provider)
        let updatesModel = updates(for: provider)
        async let account: Void = usageModel.refresh(provider, read: read)
        async let version: Void = updatesModel.refresh(provider)
        _ = await (account, version)
    }
}

/// The agents this Mac's own host runs tasks with.
struct AgentsSettingsView: View {
    @Environment(AppModel.self) private var app
    @Bindable var globalAgents: GlobalAgentsStore
    @State private var models = AgentProviderModels()
    @State private var refreshToken = 0

    private var providers: [WireProvider] {
        app.localHost?.tasks?.providers ?? []
    }

    var body: some View {
        NavigationStack {
            overviewForm
                .navigationDestination(for: AgentProvider.self) { provider in
                    let isAvailable = providers.first(where: { $0.provider == provider })?.isAvailable ?? false
                    AgentProviderDetailView(
                        provider: provider,
                        isAvailable: isAvailable,
                        usage: models.usage(for: provider),
                        updates: models.updates(for: provider),
                        globalAgents: globalAgents
                    ) {
                        app.localHost?.send(.refreshTasks)
                        globalAgents.refresh()
                        if isAvailable {
                            Task { await models.refresh(provider, read: app.readUsage) }
                        }
                    }
                }
        }
        // Looks again for agents, which may have been installed since launch.
        .task {
            app.localHost?.send(.refreshTasks)
            globalAgents.refresh()
        }
        .task(id: refreshTaskKey) {
            let readUsage = app.readUsage
            await withTaskGroup(of: Void.self) { group in
                for provider in providers where provider.isAvailable {
                    group.addTask { await models.refresh(provider.provider, read: readUsage) }
                }
            }
        }
    }

    private var refreshTaskKey: String {
        let available = providers.filter(\.isAvailable).map(\.provider.rawValue).joined(separator: ",")
        return "\(refreshToken):\(available)"
    }

    private var overviewForm: some View {
        @Bindable var settings = app.integrationSettings
        return Form {
            Section {
                Picker("Permissions for new chats", selection: $settings.defaultPermissionMode) {
                    ForEach(PermissionMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode)
                    }
                }
            }

            Section {
                ForEach(providers) { provider in
                    NavigationLink(value: provider.provider) {
                        AgentProviderSummaryRow(
                            provider: provider,
                            usage: models.usage(for: provider.provider),
                            updates: models.updates(for: provider.provider),
                            unlinkedCount: globalAgents.unlinkedCount(for: provider.provider)
                        )
                    }
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Select a provider to inspect account usage, CLI updates, and ~/.agents symlinks.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sectionActions {
                if globalAgents.hasQuickLinkableTargets {
                    Button("Link All") {
                        globalAgents.linkAllSafe()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-detect installed agents, usage, CLI updates, and links")
            }
        }
    }

    private func refresh() {
        app.localHost?.send(.refreshTasks)
        globalAgents.refresh()
        refreshToken += 1
    }
}

private struct AgentProviderSummaryRow: View {
    let provider: WireProvider
    let usage: AgentUsageModel
    let updates: AgentCLIUpdateModel
    let unlinkedCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderIcon(provider: provider.provider, isLive: provider.isAvailable)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.provider.name)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if provider.isAvailable {
                if unlinkedCount > 0 {
                    Text("\(unlinkedCount) unlinked")
                        .foregroundStyle(.orange)
                } else {
                    Text("Linked")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subtitle: String {
        guard provider.isAvailable else { return "Not installed" }
        var parts: [String] = []
        if let plan = usage.snapshot.plan, !plan.isEmpty {
            parts.append(plan)
        } else if usage.snapshot.status != "Loading…" {
            parts.append(usage.snapshot.status)
        }
        if let primary = usage.snapshot.windows.first {
            let pct = (primary.usedPercent / 100).formatted(.percent.precision(.fractionLength(0)))
            parts.append("\(pct) used")
        }
        if updates.updateAvailable {
            parts.append("Update available")
        }
        if parts.isEmpty {
            return usage.snapshot.status
        }
        return parts.joined(separator: " · ")
    }
}
