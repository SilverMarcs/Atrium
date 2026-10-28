import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }

            Tab("Agents", systemImage: "puzzlepiece.extension") {
                IntegrationsSettingsView()
            }

            Tab("Hosts", systemImage: "network") {
                HostsSettingsView()
            }

            Tab("Updates", systemImage: "arrow.down.circle") {
                UpdatesSettingsView()
            }

            Tab("Shortcuts", systemImage: "keyboard") {
                ShortcutsSettingsView()
            }

            Tab("Credits", systemImage: "heart") {
                CreditsSettingsView()
            }
        }
        .frame(width: 480, height: 520)
    }
}
