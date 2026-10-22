import SwiftUI

struct IntegrationsSettingsView: View {
    @Environment(AgentIntegrationStore.self) private var integrations

    var body: some View {
        @Bindable var integrations = integrations
        Form {
            Section {
                ForEach(integrations.providers) { provider in
                    Toggle(isOn: $integrations[isEnabled: provider]) {
                        Label {
                            Text(provider.name)
                        } icon: {
                            Image(provider.symbolName)
                                .foregroundStyle(provider.color)
                        }
                    }
                }
            } header: {
                Text("Integrations")
            } footer: {
                Text("Uses your installed command-line apps and their existing sign-in.")
            }
        }
        .formStyle(.grouped)
    }
}
