import AtriumProtocol
import SwiftUI

/// The command console's input: a field that grows with its draft, with the
/// Keys menu inside it while the command runs, and a Send button. Return
/// submits and keeps the field open for the next line.
struct CommandInputBar: View {
    let command: WireCommand
    @Bindable var console: CommandConsole

    @FocusState private var isFocused: Bool

    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 0) {
                    TextField(command.isRunning ? "Reply" : "Run a command", text: $console.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(command.isRunning ? .send : .go)
                        .focused($isFocused)
                        .lineLimit(1 ... 7)
                        .padding(.horizontal, 4)
                        .padding(8)
                        .onSubmit(submit)

                    if command.isRunning {
                        CommandKeysMenu { console.perform(.key($0)) }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
                .glassEffect(in: .rect(cornerRadius: 20))

                Button("Send", systemImage: "arrow.up", action: submit)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .bold()
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .opacity(canSubmit ? 0.85 : 0.35)
                    .allowsHitTesting(canSubmit)
                    .offset(y: -2)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, isFocused ? 8 : 0)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A running command takes an empty reply as Return; a script needs text.
    private var canSubmit: Bool {
        command.isRunning || !console.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Submits the draft, keeping the field focused for the next line.
    private func submit() {
        let wasFocused = isFocused
        console.submit()
        guard wasFocused else { return }
        // Wait a turn so focus lands after Return's own focus change.
        Task {
            await Task.yield()
            isFocused = true
        }
    }
}
