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

            Tab("Quick Panel", systemImage: "bolt.fill") {
                QuickPanelSettingsView()
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
        .frame(width: 540, height: 500)
    }
}

#Preview {
    SettingsView()
}
