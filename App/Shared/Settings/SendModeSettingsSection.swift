import SwiftUI

struct SendModePicker: View {
    var showsSubtitle = true
    @AppStorage(SendMode.key) private var sendMode = SendMode.steer

    var body: some View {
        Picker(selection: $sendMode) {
            ForEach(SendMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        } label: {
            Text("Send mode")
            if showsSubtitle {
                Text("When an agent is working")
            }
        }
    }
}

struct SendModeSettingsSection: View {
    #if os(iOS)
    @AppStorage(ComposerHaptics.enabledKey) private var hapticsEnabled = true
    #endif

    var body: some View {
        Section {
            SendModePicker()
            #if os(iOS)
            Toggle("Haptics", isOn: $hapticsEnabled)
            #endif
        }
    }
}
