import SwiftUI

/// The agents this Mac's own host runs tasks with.
struct IntegrationsSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                ForEach(app.localHost?.tasks?.providers ?? []) { provider in
                    Toggle(isOn: Binding(
                        get: { provider.isEnabled },
                        set: { app.localHost?.send(.setProviderEnabled(provider.provider, $0)) }
                    )) {
                        Label {
                            Text(provider.provider.name)
                        } icon: {
                            Image(provider.provider.symbolName)
                                .foregroundStyle(provider.provider.color)
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
