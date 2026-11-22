import AtriumClient
import AtriumProtocol
import SwiftUI

struct NewChatHostPicker: View {
    let hosts: HostDirectory
    let host: HostClient

    var body: some View {
        Menu {
            Picker("Host", selection: Binding(
                get: { host.id },
                set: { id in
                    guard let host = hosts.host(id), host.canStartTask,
                          let workspaceID = host.defaultWorkspaceID else { return }
                    hosts.openNewChat(in: WorkspaceRef(hostID: id, workspaceID: workspaceID))
                }
            )) {
                ForEach(hosts.hosts) { host in
                    Label(host.name, systemImage: host.canStartTask ? host.icon.symbolName : "exclamationmark.triangle")
                        .tag(host.id)
                        .disabled(!host.canStartTask)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            NewChatPickerLabel(title: host.name) {
                Image(systemName: host.icon.symbolName)
            }
        }
        .accessibilityLabel("Host")
        .accessibilityValue(host.name)
    }
}
