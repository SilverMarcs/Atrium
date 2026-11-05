import AppKit
import AtriumClient
import AtriumProtocol
import SwiftUI

/// A command's output and what's typed into it, on whichever host the project is.
struct CommandConsoleView: View {
    let command: WireCommand
    let console: CommandConsole
    let project: Project
    // Saved commands used a fixed 12-point font in the embedded terminal.
    private let fontSize: Double = 12

    var body: some View {
        VStack(spacing: 0) {
            CommandConsoleHeader(command: command, console: console, project: project)
            CommandOutputTextView(output: console.output, fontSize: fontSize, openLink: openLink)
            Divider()
            CommandInputBar(command: command, console: console, fontSize: fontSize)
        }
        .task(id: command.id) { await project.host.follow(console.topic) }
    }

    /// Opens a link from the output as chat does: a file in the project in
    /// its editor, a file elsewhere on this Mac in Finder, a web page in the browser.
    private func openLink(_ link: String) {
        if let url = URL(string: link), url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            return
        }
        let directory = command.directory ?? project.root.filePath
        Task {
            if await !project.openLink(link, from: directory), project.isLocal {
                FileService.openOutsideProject(link, relativeTo: directory)
            }
        }
    }
}

private struct CommandConsoleHeader: View {
    let command: WireCommand
    let console: CommandConsole
    let project: Project

    private let buttonSize: CGFloat = 26

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Button("Clear", systemImage: "delete.left") { console.perform(.clear) }
                    .help("Clear the output")
                    .frame(width: buttonSize, height: buttonSize)
                    .background(.secondary.opacity(0.15), in: .circle)
                if command.isRunning || command.canRun {
                    Button(command.isRunning ? "Stop" : "Run", systemImage: command.isRunning ? "stop.fill" : "play.fill") {
                        project.toggle(command)
                    }
                    .contentTransition(.symbolEffect(.replace))
                    .help(command.isRunning ? "Stop, and again to force it" : "Run")
                    .frame(width: buttonSize, height: buttonSize)
                    .background(.secondary.opacity(0.15), in: .circle)
                }
            }
            .labelStyle(.iconOnly)
            .font(.caption2)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// How the latest run is going, as iOS shows it.
    private var subtitle: String? { command.status }
}

/// Types a reply into the running command, or runs a one-off script while it's
/// stopped. Arrow keys recall earlier scripts, or go to the program while it
/// runs and nothing is typed; Control-C and Control-D always go to it.
private struct CommandInputBar: View {
    let command: WireCommand
    @Bindable var console: CommandConsole
    let fontSize: Double
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: command.isRunning ? "arrowshape.turn.up.left" : "chevron.right")
                .foregroundStyle(.tertiary)
                .contentTransition(.symbolEffect(.replace))
            ZStack(alignment: .leading) {
                if console.draft.isEmpty {
                    Text(command.isRunning ? "Reply" : "Run in \(console.host.displayPath(console.directory))")
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $console.draft)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
                    .focused($isFocused)
                    .onSubmit {
                        console.submit()
                        isFocused = true
                    }
                    .onKeyPress(phases: .down, action: handle)
            }
            .font(.system(size: fontSize, weight: .light, design: .monospaced))
            if command.isRunning {
                CommandKeysMenu { console.perform(.key($0)) }
                    .labelStyle(.iconOnly)
                    .menuIndicator(.hidden)
                    .buttonStyle(.borderless)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers == .control, command.isRunning {
            switch press.key.character {
            case "c", "\u{03}": console.perform(.key(.interrupt))
            case "d", "\u{04}": console.perform(.key(.endOfInput))
            default: return .ignored
            }
            return .handled
        }
        guard press.modifiers.isEmpty, press.key == .upArrow || press.key == .downArrow else { return .ignored }
        let isUp = press.key == .upArrow
        if command.isRunning {
            guard console.draft.isEmpty else { return .ignored }
            console.perform(.key(isUp ? .up : .down))
        } else if isUp {
            console.recallPrevious()
        } else {
            console.recallNext()
        }
        return .handled
    }
}
