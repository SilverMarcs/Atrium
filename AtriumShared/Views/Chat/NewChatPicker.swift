import AtriumClient
import AtriumProtocol
import SwiftUI

/// Chooses where a new chat starts, above the composer.
struct NewChatPicker: View {
    let hosts: HostDirectory
    let host: HostClient
    let draft: TaskDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if host.enabledProviders.isEmpty {
                Text("Turn on Codex or Claude in Atrium’s settings on \(host.name).")
                    .foregroundStyle(.secondary)
                    .padding(.bottom)
            }
            NewChatHostPicker(hosts: hosts, host: host)
            NewChatProjectPicker(hosts: hosts, host: host, draft: draft)
            NewChatAgentPicker(host: host, draft: draft)
            NewChatModelPicker(host: host, draft: draft)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .menuIndicator(.hidden)
        .padding(.horizontal)
        .padding(.bottom, 4)
        #else
        .padding(.leading, 31)
        .padding(.trailing)
        .padding(.bottom)
        #endif
    }
}
