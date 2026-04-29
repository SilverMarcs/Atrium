import SwiftUI

struct CompanionRootView: View {
    @Environment(CompanionClient.self) private var client
    @State private var path: [Route] = []
    /// Stashes a notification-tap deeplink whose target workspace isn't
    /// in `client.workspaces` yet (cold launch). Resolved when the next
    /// `sessionsList` lands.
    @State private var unresolvedDeepLink: PendingDeepLink?

    var body: some View {
        NavigationStack(path: $path) {
            // Gate on `hasConnectedBefore` rather than the live connection
            // state — once we've successfully paired, we stay on the
            // workspaces flow even when reconnecting after a background
            // wake. Reset only on user-initiated disconnect or auth
            // rejection, both of which the client handles.
            Group {
                if client.hasConnectedBefore {
                    WorkspacesScreen()
                } else {
                    PairingScreen()
                }
            }
            .navigationTitle("Atrium")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .workspace(let workspace):
                    ChatsScreen(workspace: workspace)
                case .chat(let sessionId):
                    SessionDetailScreen(sessionId: sessionId)
                case .sourceControl(let workspaceId):
                    SourceControlScreen(workspaceId: workspaceId)
                case .fileDiff(let workspaceId, let path, let stage, let name):
                    FileDiffScreen(workspaceId: workspaceId, path: path, stage: stage, name: name)
                case .commands(let workspaceId):
                    CommandsScreen(workspaceId: workspaceId)
                }
            }
        }
        .task {
            client.startBrowsing()
        }
        .onChange(of: client.pendingDeepLink) { _, link in
            guard let link else { return }
            applyDeepLink(link)
            client.pendingDeepLink = nil
        }
        .onChange(of: client.workspaces) { _, _ in
            // A deferred deeplink may now be applicable.
            if let link = unresolvedDeepLink {
                applyDeepLink(link)
            }
        }
    }

    /// Navigates to `[workspace, chat]`. If the user is already on the
    /// matching workspace's chats screen, appends the chat onto the
    /// existing path so we don't disturb the workspace entry (the path's
    /// stale `WireWorkspace` value differs from the fresh one in
    /// `client.workspaces` and a full replace would cause a pop/push
    /// glitch). If the workspace isn't loaded yet (cold launch from a
    /// notification tap), parks the link until the next `sessionsList`.
    private func applyDeepLink(_ link: PendingDeepLink) {
        guard let workspace = client.workspaces.first(where: { $0.id == link.workspaceId }) else {
            unresolvedDeepLink = link
            return
        }
        if let last = path.last, case let .workspace(ws) = last, ws.id == link.workspaceId {
            path.append(.chat(link.sessionId))
        } else {
            path = [.workspace(workspace), .chat(link.sessionId)]
        }
        unresolvedDeepLink = nil
    }
}
