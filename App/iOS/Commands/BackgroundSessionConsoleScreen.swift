import SwiftUI

/// Live output for an agent-run background shell session on its host.
struct BackgroundSessionConsoleScreen: View {
    let host: HostClient
    let workspaceID: UUID
    let sessionID: String

    private var session: WireBackgroundSession? {
        host.workspace(workspaceID)?.backgroundSessions.first { $0.id == sessionID }
    }

    private var output: WireCommandOutput? {
        host.backgroundSessionOutputs[sessionID]
    }

    var body: some View {
        Group {
            if host.workspace(workspaceID) != nil, session == nil,
               output == nil || output?.lines.isEmpty == true {
                ContentUnavailableView(
                    "Session Ended",
                    systemImage: "terminal",
                    description: Text("This background session is no longer running.")
                )
            } else {
                CommandOutputLines(output: output)
                    .overlay {
                        if output?.lines.isEmpty == true {
                            Text("No Output")
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .navigationTitle(session?.chatTitle ?? "Background Session")
        .navigationSubtitle(session?.command ?? "Ended")
        .toolbarTitleDisplayMode(.inline)
        .task(id: sessionID) {
            await host.follow(.backgroundSessionOutput(workspaceID: workspaceID, sessionID: sessionID))
        }
    }
}
