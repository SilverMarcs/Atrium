import SwiftUI

/// A task list row, shared by every client: the title and status, then the
/// project and, when several hosts are listed, the host it's on, any snooze
/// time, any background shell its agent left running, and the agent, grayed
/// out once its session has ended.
// TODO: Tapping a task that waits on an approval or question should offer
// its answers right in the list (a popover or menu on the row), without
// opening the chat.
struct TaskRowContent<ProjectIcon: View>: View {
    let title: String
    let projectName: String
    var hostName: String? = nil
    /// The symbol of the host it's on, shown with or instead of its name.
    let hostSymbol: String
    let hostLabel: TaskRowHostLabel
    let provider: AgentProvider
    let status: AgentThreadStatus
    /// The request it's waiting on, which picks its status symbol.
    var waitingOn: AgentInteraction? = nil
    let hasUnreadResult: Bool
    let isSettled: Bool
    let snoozedUntil: Date?
    var pullRequests: [PullRequest] = []
    /// Titles of the background shells its agent started that still run.
    var backgroundShells: [String] = []
    var isDictating = false
    @ViewBuilder let projectIcon: ProjectIcon
    @ScaledMetric(relativeTo: .subheadline) private var shellIconScale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .lineLimit(1)

                Spacer()

                if isDictating {
                    DictatingIndicator()
                }

                TaskStatusIndicator(status: status, hasUnreadResult: hasUnreadResult, isSettled: isSettled, waitingOn: waitingOn)
                    .controlSize(.mini)
                    .font(.caption2)
            }
            HStack(spacing: 5) {
                projectIcon
                Text(projectName)
                    .lineLimit(1)
                if let hostName {
                    Label(hostName, systemImage: hostSymbol)
                        .labelStyle(hostLabel)
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                        .help(hostName)
                }

                Spacer(minLength: 0)

                if let snoozedUntil {
                    Text(snoozedUntil, format: .dateTime.weekday().hour().minute())
                        .lineLimit(1)
                        .help("Snoozed until \(snoozedUntil.formatted(date: .abbreviated, time: .shortened))")
                }

                PullRequestIndicator(pullRequests: pullRequests)

                if !backgroundShells.isEmpty {
                    ShellPromptGlyph()
                        .stroke(.foreground, style: StrokeStyle(lineWidth: 1.25 * shellIconScale, lineCap: .round, lineJoin: .round))
                        .frame(width: 15 * shellIconScale, height: 12 * shellIconScale)
                        .accessibilityLabel("Background shell running")
                        .accessibilityAddTraits(.isImage)
                        .help(backgroundShells.joined(separator: "\n"))
                }

                ProviderIcon(provider: provider, isLive: status.isLive)
                    .help(provider.name)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 1)
    }
}

private struct ShellPromptGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 2, y: 2.5))
        path.addLine(to: CGPoint(x: 6.25, y: 6))
        path.addLine(to: CGPoint(x: 2, y: 9.5))
        path.move(to: CGPoint(x: 8.25, y: 9.5))
        path.addLine(to: CGPoint(x: 13, y: 9.5))

        let scale = rect.width / 15
        return path.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// The composer's recording waveform, for a chat that's recording while closed.
private struct DictatingIndicator: View {
    var body: some View {
        Label("Dictating", systemImage: "waveform")
            .labelStyle(.iconOnly)
            .font(.caption)
            .foregroundStyle(.tint)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers.reversing, options: .repeat(.continuous))
            .help("Dictating")
    }
}
