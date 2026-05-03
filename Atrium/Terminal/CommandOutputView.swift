import SwiftUI

struct CommandOutputView: View {
    let command: Command
    @AppStorage(TerminalFontSize.key) private var fontSize: Double = Double(TerminalFontSize.defaultSize)
    @State private var input: String = ""
    @State private var historyCursor: Int? = nil
    @State private var draftBeforeRecall: String = ""
    @State private var contentHeight: CGFloat = 0
    @FocusState private var inputFocused: Bool

    private let barHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(statusLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 6) {
                    HStack(spacing: 0) {
                        Button {
                            fontSize = max(Double(TerminalFontSize.min), fontSize - 0.5)
                        } label: {
                            Image(systemName: "textformat.size.smaller")
                        }
                        .help("Decrease font size")

                        Divider()
                            .frame(height: 12)
                            .padding(.horizontal, 4)

                        Button {
                            fontSize = min(Double(TerminalFontSize.max), fontSize + 0.5)
                        } label: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .help("Increase font size")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: barHeight)
                    .background(.secondary.opacity(0.15), in: Capsule())

                    if !command.isRunning, hasRunScript {
                        Button {
                            command.run()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                        }
                        .help("Run")
                        .frame(width: barHeight, height: barHeight)
                        .background(.secondary.opacity(0.15), in: Circle())
                    }

                    if command.isRunning {
                        Button {
                            command.interrupt()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.caption2)
                        }
                        .help("Interrupt (SIGINT)")
                        .frame(width: barHeight, height: barHeight)
                        .background(.secondary.opacity(0.15), in: Circle())
                    }

                    Button {
                        command.clearOutput()
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.caption2)
                    }
                    .help("Clear output (⌘K)")
                    .keyboardShortcut("k", modifiers: .command)
                    .frame(width: barHeight, height: barHeight)
                    .background(.secondary.opacity(0.15), in: Circle())
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)

            CommandTextView(
                text: command.output.text,
                fontSize: CGFloat(fontSize),
                onContentHeight: { contentHeight = $0 }
            )
            // When content is short, this caps the view to its content
            // height so the input bar floats up just under the last line.
            // When content is tall, the VStack's available space caps it
            // first and the scroll view scrolls inside.
            .frame(maxHeight: contentHeight > 0 ? contentHeight : .infinity)

            inputBar

            Spacer(minLength: 0)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: CGFloat(fontSize)).monospaced())
                .focused($inputFocused)
                .onSubmit(submit)
                .onKeyPress(.upArrow) {
                    recallPrevious()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    recallNext()
                    return .handled
                }
        }
        .padding(.trailing, 11)
        .padding(.leading, 6)
        .padding(.vertical, 6)
        .background(.clear)
    }

    private func submit() {
        let line = input
        input = ""
        historyCursor = nil
        draftBeforeRecall = ""
        if command.isRunning {
            // Echo locally — without a TTY the program won't echo. Prefix with
            // `> ` so stdin replies are visually distinct from program output
            // and from `$ <cmd>` lines.
            command.output.append("> \(line)\n")
            command.sendInput(line + "\n")
        } else {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            command.recordHistory(line)
            command.runScript(line)
        }
        inputFocused = true
    }

    private func recallPrevious() {
        let history = command.inputHistory
        guard !history.isEmpty else { return }
        let next: Int
        if let cur = historyCursor {
            next = max(0, cur - 1)
        } else {
            draftBeforeRecall = input
            next = history.count - 1
        }
        historyCursor = next
        input = history[next]
    }

    private func recallNext() {
        let history = command.inputHistory
        guard let cur = historyCursor else { return }
        let next = cur + 1
        if next >= history.count {
            historyCursor = nil
            input = draftBeforeRecall
            draftBeforeRecall = ""
        } else {
            historyCursor = next
            input = history[next]
        }
    }

    private var hasRunScript: Bool {
        guard let s = command.runScript?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !s.isEmpty
    }

    private var statusLabel: String {
        switch command.state {
        case .idle: return command.title
        case .running: return "\(command.title) — running"
        case .finished(let code):
            return code == 0 ? command.title : "\(command.title) — exit \(code)"
        }
    }
}
