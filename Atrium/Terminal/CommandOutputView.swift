import SwiftUI

struct CommandOutputView: View {
    let command: Command
    @AppStorage(TerminalFontSize.key) private var fontSize: Double = Double(TerminalFontSize.defaultSize)

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

                    Button {
                        command.clearOutput()
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.caption2)
                    }
                    .help("Clear output")
                    .frame(width: barHeight, height: barHeight)
                    .background(.secondary.opacity(0.15), in: Circle())
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)

            CommandTextView(command: command, fontSize: CGFloat(fontSize))
        }
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
