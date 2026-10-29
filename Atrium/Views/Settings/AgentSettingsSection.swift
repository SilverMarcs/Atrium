import SwiftUI

struct AgentSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var usage = AgentUsageModel()
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
        }
        .task { await usage.refresh(provider.provider) }
    }
}
