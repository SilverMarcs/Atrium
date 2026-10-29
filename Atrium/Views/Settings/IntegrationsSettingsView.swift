import AtriumClient
import AtriumProtocol
import SwiftUI

/// The agents this Mac's own host runs tasks with.
struct IntegrationsSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            ForEach(app.localHost?.tasks?.providers ?? []) { provider in
                AgentSettingsSection(provider: provider)
            }
        }
        .formStyle(.grouped)
    }
}
