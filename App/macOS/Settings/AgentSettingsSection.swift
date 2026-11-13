import AtriumClient
import AtriumProtocol
import SwiftUI

struct AgentSettingsSection: View {
    @State private var usage = AgentUsageModel()
    @State private var updates = AgentCLIUpdateModel()
    let provider: WireProvider

    var body: some View {
        if provider.isAvailable {
            installed
        } else {
            Section {
                LabeledContent("Status", value: "Not installed")
            } header: {
                header
            } footer: {
                HStack {
                    Text("Atrium finds \(provider.provider.name) on its own once it’s installed.")
                    Spacer()
                    Link("Installation Guide", destination: provider.provider.installationGuide)
                }
            }
        }
    }

    private var installed: some View {
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
            header
        } footer: {
            HStack {
                Text(updates.status)
                Spacer()
                Button(updates.buttonTitle, action: update)
                    .disabled(updates.isDisabled)
            }
        }
        .task {
            async let account: Void = usage.refresh(provider.provider)
            async let version: Void = updates.refresh(provider.provider)
            _ = await (account, version)
        }
        .alert("Couldn’t Update \(provider.provider.name)", isPresented: $updates.showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(updates.errorMessage)
        }
    }

    private var header: some View {
        Label {
            Text(provider.provider.name)
        } icon: {
            Image(provider.provider.symbolName)
                .foregroundStyle(provider.provider.color)
        }
    }

    private func update() {
        Task { await updates.performAction(provider.provider) }
    }
}

private extension AgentProvider {
    var installationGuide: URL {
        switch self {
        case .codex: URL(string: "https://developers.openai.com/codex/cli")!
        case .claude: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!
        case .jcode: URL(string: "https://github.com/1jehuang/jcode#installation")!
        }
    }
}
