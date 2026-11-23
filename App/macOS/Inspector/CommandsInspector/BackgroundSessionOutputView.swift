import SwiftUI

/// An agent's background shell session's output, or "No Output" until it prints something.
struct BackgroundSessionOutputView: View {
    let session: WireBackgroundSession
    let project: Project

    private var output: WireCommandOutput? { project.host.backgroundSessionOutputs[session.id] }

    var body: some View {
        CommandOutputTextView(output: output) { project.openLink($0, from: session.directory) }
            .overlay {
                if output?.lines.isEmpty == true {
                    Text("No Output")
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: session.id) {
                await project.host.follow(.backgroundSessionOutput(workspaceID: project.workspaceID, sessionID: session.id))
            }
    }
}
