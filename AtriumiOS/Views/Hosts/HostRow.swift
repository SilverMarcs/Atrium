import SwiftUI

struct HostRow: View {
    let host: HostClient
    let onRename: () -> Void

    var body: some View {
        Button(action: onRename) {
            HostLabel(host: host)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
