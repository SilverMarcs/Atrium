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
            if host.availableProviders.isEmpty {
                Text("Install Claude Code or Codex on \(host.name) to start a chat.")
                    .foregroundStyle(.secondary)
                    .padding(.bottom)
            }
            NewChatHostPicker(hosts: hosts, host: host)
            NewChatProjectPicker(hosts: hosts, host: host, draft: draft)
            NewChatAgentPicker(host: host, draft: draft)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .menuIndicator(.hidden)
        .padding(.horizontal)
        .padding(.bottom, 12.5)
        #else
        // At the end of the timeline, within its margins.
        .padding(.leading, 16)
        #endif
    }
}
