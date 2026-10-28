import SwiftUI

/// Names a paired host on this device only; an empty name goes back to the
/// host's own.
struct HostRenameAlert: ViewModifier {
    @Binding var renaming: HostClient?
    let hosts: HostDirectory
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Host", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                   presenting: renaming) { host in
                TextField(host.pairedHost?.hostName ?? host.name, text: $name)
                Button("Rename") { hosts.rename(host, to: name) }
                Button("Cancel", role: .cancel) {}
            } message: { host in
                Text("Leave it empty to use “\(host.pairedHost?.hostName ?? host.name)”.")
            }
            .onChange(of: renaming?.id) {
                name = renaming?.name ?? ""
            }
    }
}

extension View {
    func hostRenameAlert(_ host: Binding<HostClient?>, in hosts: HostDirectory) -> some View {
        modifier(HostRenameAlert(renaming: host, hosts: hosts))
    }
}
