import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }

            Tab("Agents", systemImage: "cpu") {
                ChatSettingsView()
            }

            Tab("Shortcuts", systemImage: "keyboard") {
                ShortcutsSettingsView()
            }

            Tab("Companion", systemImage: "iphone.gen3") {
                CompanionSettingsView()
            }

            Tab("Credits", systemImage: "heart") {
                CreditsSettingsView()
            }
        }
        .frame(width: 480, height: 440)
    }
}

#Preview {
    SettingsView()
}
