import SwiftUI

/// The new chat's empty timeline, where the host, project and agent its task
/// is created with are chosen before the first prompt is sent.
struct NewChatPicker: View {
    let hosts: HostDirectory
    let host: HostClient
    let draft: TaskDraft

    var body: some View {
        if host.enabledProviders.isEmpty {
            ContentUnavailableView {
                Label("No Agents Enabled", systemImage: "sparkles")
            } description: {
                Text("Turn on Codex or Claude in Atrium’s settings on \(host.name).")
            } actions: {
                NewChatPlacePicker(hosts: hosts, host: host, draft: draft)
            }
        } else {
            ContentUnavailableView {
                Label {
                    Text(draft.provider.name)
                } icon: {
                    ProviderIcon(provider: draft.provider)
                        .contentTransition(.symbolEffect(.replace))
                }
            } actions: {
                if host.enabledProviders.count > 1 {
                    Picker("Agent", selection: Binding(
                        get: { draft.provider },
                        set: { host.setProvider($0, ofDraft: draft.id) }
                    ).animation()) {
                        ForEach(host.enabledProviders) { provider in
                            Text(provider.name)
                                .tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                NewChatPlacePicker(hosts: hosts, host: host, draft: draft)
            }
        }
    }
}

/// The host and project the new chat starts in.
private struct NewChatPlacePicker: View {
    let hosts: HostDirectory
    let host: HostClient
    let draft: TaskDraft

    var body: some View {
        HStack {
            if hosts.newChatHosts.contains(where: { $0.id != host.id }) {
                Picker("Host", selection: Binding(
                    get: { host.id },
                    set: { id in
                        guard let host = hosts.host(id), let workspaceID = host.defaultWorkspaceID else { return }
                        hosts.openNewChat(in: WorkspaceRef(hostID: id, workspaceID: workspaceID))
                    }
                )) {
                    ForEach(hosts.hosts.filter { $0.id == host.id || $0.canStartTask }) { host in
                        Text(host.name)
                            .tag(host.id)
                    }
                }
            }
            Picker("Project", selection: Binding(
                get: { draft.workspaceID },
                set: { hosts.openNewChat(in: WorkspaceRef(hostID: host.id, workspaceID: $0)) }
            )) {
                ForEach(host.tasks?.workspaces ?? []) { workspace in
                    Label {
                        Text(workspace.name)
                    } icon: {
                        // Menus draw images only, so a custom icon shows as a folder.
                        workspace.projectIcon.map { Image($0) } ?? Image(systemName: "folder")
                    }
                    .tag(workspace.id)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}
