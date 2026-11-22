import AtriumClient
import AtriumProtocol
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
            } else if session?.hasOutput == false {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let command = session?.command, !command.isEmpty {
                            Text("$ \(command)")
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                        Text("Live output isn’t available for this background session.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            } else {
                CommandOutputLines(output: output)
            }
        }
        .navigationTitle(session?.title ?? "Background Session")
        .navigationSubtitle(subtitle)
        .toolbarTitleDisplayMode(.inline)
        .task(id: sessionID) {
            await host.follow(.backgroundSessionOutput(workspaceID: workspaceID, sessionID: sessionID))
        }
    }

    private var subtitle: String {
        guard let session else { return "Ended" }
        return session.taskTitle.isEmpty ? "\(session.provider.name) · Running" : "\(session.provider.name) · \(session.taskTitle)"
    }
}
