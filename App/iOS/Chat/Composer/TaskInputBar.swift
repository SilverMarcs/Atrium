import AtriumClient
import AtriumProtocol
import SwiftUI

/// The inline composer used on iPad, in place of the iPhone's bottom-bar
/// search field: the attachment menu, a prompt field that grows with its
/// draft, and a Send button that becomes Stop while the agent works.
struct TaskInputBar: View {
    @Environment(TaskComposer.self) private var composer
    @Environment(PromptSendAnimator.self) private var sendAnimator
    let item: HostTask?
    let prompt: String
    /// Sends the draft from the field at the given frame, if known, returning
    /// whether it was sent.
    let submit: (CGRect?) -> Bool

    @FocusState private var isFocused: Bool
    /// The prompt field's leading edge, which attached images line up with.
    @State private var fieldLeading: CGFloat?

    private static let space = "TaskInputBar"

    var body: some View {
        @Bindable var composer = composer

        GlassEffectContainer {
            VStack(spacing: 0) {
                if let edit = composer.messageEdit { ConversationEditContent(edit: edit) }
                if !composer.images.isEmpty {
                    ComposerAttachmentStrip(composer: composer, leadingInset: fieldLeading)
                }

                HStack(alignment: .bottom) {
                    if item?.task.actions.contains(.attachImages) != false {
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
                    }

                    if composer.messageEdit != nil {
                        ConversationEditCancelButton(action: composer.cancelEdit)
                    }

                    HStack(alignment: .bottom, spacing: 0) {
                        TextField(composer.messageEdit == nil ? prompt : "Edit message…", text: $composer.draft, axis: .vertical)
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
                            .disabled(composer.messageEdit?.isSubmitting == true)
                            .background(ComposerPasteAnchor(composer: composer))

                        ComposerDictationButton(composer: composer, isInline: true)
                            .buttonStyle(.plain)
                    }
                    .glassEffect(in: .rect(cornerRadius: 20))
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minX } action: { fieldLeading = $0 }

                    ComposerSendButton(item: item, send: send)
                }
                .padding(.horizontal, 10)
                // Closer to the images above it than to whatever sits above them.
                .padding(.top, composer.images.isEmpty ? 8 : 3)
                .padding(.bottom, isFocused ? 8 : 0)
            }
            .coordinateSpace(.named(Self.space))
            .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: composer.messageEdit?.id) {
            guard composer.messageEdit != nil else { return }
            do { try await Task.sleep(for: TaskComposer.contextMenuDismissalDelay) }
            catch { return }
            isFocused = true
        }
        .disabled(composer.messageEdit?.isSubmitting == true)
        // Mirror focus into the composer, where the timeline observes it to
        // scroll to the latest message (FocusState is view-local).
        .onChange(of: isFocused) { _, focused in
            composer.isFocused = focused
        }
        .onDisappear {
            composer.isFocused = false
        }
    }

    /// Sends the draft, preserving whether the composer was focused.
    private func send() {
        let wasFocused = isFocused
        _ = submit(nil)
        guard wasFocused else { return }
        // Wait a turn so focus lands after Return's own focus change.
        Task {
            await Task.yield()
            isFocused = true
        }
    }
}
