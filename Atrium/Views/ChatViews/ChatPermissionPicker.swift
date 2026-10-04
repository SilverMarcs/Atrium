import SwiftUI

struct ChatPermissionPicker: View {
    @Bindable var chat: Chat

    var body: some View {
        Picker("Permission Mode", selection: Binding(get: { chat.permissionMode }, set: { chat.selectPermissionMode($0) })) {
            ForEach(chat.permissionModes) { mode in
                Label(mode.label, systemImage: mode.systemImage).tag(mode.rawValue)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .help(chat.selectedPermissionMode?.description ?? "Provider Default")
        .disabled(chat.permissionModes.isEmpty || chat.session.isConnecting)
    }
}
