import SwiftUI

struct SendModeSettingsSection: View {
    @AppStorage(SendMode.key) private var sendMode = SendMode.steer
    #if os(iOS)
    @AppStorage(ComposerHaptics.enabledKey) private var hapticsEnabled = true
    #endif

    var body: some View {
        Section {
            Picker(selection: $sendMode) {
                ForEach(SendMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Text("Send mode")
                Text("When an agent is working")
            }
            #if os(iOS)
            Toggle("Haptics", isOn: $hapticsEnabled)
            #endif
        }
    }
}
