import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }

            Tab("Agents", systemImage: "puzzlepiece.extension") {
                AgentsSettingsView()
            }

            Tab("Remote", systemImage: "network") {
                RemoteSettingsView()
            }

            Tab("Updates", systemImage: "arrow.down.circle") {
                UpdatesSettingsView()
            }

            // Shortcuts and Credits are hidden for now; their views stay.
        }
        .frame(width: 480, height: 520)
    }
}
