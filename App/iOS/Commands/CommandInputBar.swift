import SwiftUI

/// A single-line command field with a permanent terminal keys menu beside it.
struct CommandInputBar: View {
    let command: WireCommand
    @Bindable var console: CommandConsole

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(alignment: .bottom, spacing: ComposerBarLayout.restingSpacing) {
                TextField(command.isRunning ? "Reply" : "Run a command", text: $console.draft)
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(command.isRunning ? .send : .go)
                    .focused($isFocused)
                    .padding(.horizontal, ComposerEditor.horizontalInset)
                    .frame(minHeight: ComposerBarLayout.rowHeight)
                    .onSubmit(submit)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular, in: .rect(cornerRadius: ComposerBarLayout.cornerRadius))

                CommandKeysMenu { console.perform(.key($0)) }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .tint(.secondary)
                    .frame(width: ComposerBarLayout.rowHeight, height: ComposerBarLayout.rowHeight)
                    .contentShape(.circle)
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .disabled(!command.isRunning)
            }
            .padding(.horizontal, isFocused ? ComposerBarLayout.expandedMargin : ComposerBarLayout.restingMargin)
            .padding(.top, 10)
            .padding(.bottom, ComposerBarLayout.expandedMargin)
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4, extraBounce: 0.05), value: isFocused)
    }

    /// Submits the draft and closes the keyboard.
    private func submit() {
        console.submit()
        isFocused = false
    }
}
