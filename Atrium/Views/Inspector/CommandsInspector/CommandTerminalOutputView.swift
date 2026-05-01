import SwiftUI

struct CommandTerminalOutputView: View {
    let terminal: Terminal

    private let barHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(terminal.foregroundProcessName ?? terminal.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 6) {
                    HStack(spacing: 0) {
                        Button { terminal.decreaseFontSize() } label: {
                            Image(systemName: "textformat.size.smaller")
                        }
                        .help("Decrease font size")

                        Divider()
                            .frame(height: 12)
                            .padding(.horizontal, 4)

                        Button { terminal.increaseFontSize() } label: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .help("Increase font size")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: barHeight)
                    .background(.secondary.opacity(0.15), in: Capsule())

                    Button { terminal.clearTerminal() } label: {
                        Image(systemName: "delete.left")
                            .font(.caption2)
                    }
                    .help("Reset terminal")
                    .frame(width: barHeight, height: barHeight)
                    .background(.secondary.opacity(0.15), in: Circle())
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)
            // .frame(height: 36)

            TerminalContainerRepresentable(tab: terminal)
        }
    }
}
