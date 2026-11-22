import AppKit
import AtriumClient
import AtriumProtocol
import SwiftUI

/// Live output view for an agent-run background shell session in the Commands inspector.
struct BackgroundSessionConsoleView: View {
    let session: WireBackgroundSession
    let project: Project
    private let fontSize: Double = 12

    private var output: WireCommandOutput? {
        project.host.backgroundSessionOutputs[session.id]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ProviderIcon(provider: session.provider)
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            if session.hasOutput {
                CommandOutputTextView(output: output, fontSize: fontSize, openLink: openLink)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !session.command.isEmpty {
                            Text("$ \(session.command)")
                                .font(.system(size: fontSize, weight: .light, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Text("Live output isn’t available for this background session.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
            }
        }
        .task(id: session.id) {
            guard session.hasOutput else { return }
            await project.host.follow(.backgroundSessionOutput(workspaceID: project.workspaceID, sessionID: session.id))
        }
    }

    private var subtitle: String {
        if session.taskTitle.isEmpty {
            return "\(session.provider.name) · Running"
        }
        return "\(session.provider.name) · \(session.taskTitle)"
    }

    private func openLink(_ link: String) {
        if let url = URL(string: link), url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            return
        }
        let directory = session.directory.isEmpty ? project.root.filePath : session.directory
        Task {
            if await !project.openLink(link, from: directory), project.isLocal {
                FileService.openOutsideProject(link, relativeTo: directory)
            }
        }
    }
}
