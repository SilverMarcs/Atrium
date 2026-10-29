import SwiftUI

struct AgentSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var usage = AgentUsageModel()
    @State private var updates = AgentCLIUpdateModel()
    let provider: WireProvider

    var body: some View {
        Section {
            Toggle("Enabled", isOn: Binding(
                get: { provider.isEnabled },
                set: { app.localHost?.send(.setProviderEnabled(provider.provider, $0)) }
            ))
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
            Label {
                Text(provider.provider.name)
            } icon: {
                Image(provider.provider.symbolName)
                    .foregroundStyle(provider.provider.color)
            }
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

    private func update() {
        Task { await updates.performAction(provider.provider) }
    }
}
