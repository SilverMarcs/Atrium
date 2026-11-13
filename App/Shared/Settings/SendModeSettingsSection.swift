import SwiftUI

struct SendModeSettingsSection: View {
    @AppStorage(SendMode.key) private var sendMode = SendMode.steer

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
        }
    }
}
