import SwiftUI

/// The inline composer used on iPad, in place of the iPhone's bottom-bar
/// search field: the attachment menu, a prompt field that grows with its
/// draft, and a Send button that becomes Stop while the agent works.
struct TaskInputBar: View {
    @Environment(TaskComposer.self) private var composer
    @Environment(PromptSendAnimator.self) private var sendAnimator
    let task: WireTask?
    let prompt: String
    /// Sends the draft from the field at the given frame, if known, returning
    /// whether it was sent.
    let submit: (CGRect?) -> Bool

    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var composer = composer

        GlassEffectContainer {
            VStack(spacing: 0) {
                if !composer.images.isEmpty {
                    ComposerAttachmentStrip(composer: composer)
                }

                HStack(alignment: .bottom) {
                    ComposerAttachmentMenu {
                        Label("Attach", systemImage: "plus.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary, .clear)
                            .font(.largeTitle)
                            .glassEffect()
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .scaleEffect(0.97)

                    HStack(alignment: .bottom, spacing: 0) {
                        TextField(prompt, text: $composer.draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .focused($isFocused)
                            .lineLimit(1 ... 7)
                            .padding(.horizontal, 4)
                            .padding(8)
                            .onGeometryChange(for: CGRect.self) { geometry in
                                geometry.frame(in: .global)
                            } action: { frame in
                                sendAnimator.sourceFrame = { frame }
                            }
                            .onSubmit(send)
                            .background(ComposerPasteAnchor(composer: composer))

                        ComposerDictationButton(isInline: true)
                            .buttonStyle(.plain)
                    }
                    .glassEffect(in: .rect(cornerRadius: 20))

                    ComposerSendButton(task: task, send: send)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, isFocused ? 8 : 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        // Mirror focus into the composer, where the timeline observes it to
        // scroll to the latest message (FocusState is view-local).
        .onChange(of: isFocused) { _, focused in
            composer.isFocused = focused
        }
        .onDisappear {
            composer.isFocused = false
        }
    }

    /// Sends the draft, keeping the keyboard up for the next prompt.
    private func send() {
        _ = submit(nil)
        // Wait a turn so focus lands after Return's own focus change.
        Task {
            await Task.yield()
            isFocused = true
        }
    }
}
