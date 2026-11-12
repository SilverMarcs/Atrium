import AtriumClient
import AtriumProtocol
import SwiftUI

/// The iPhone's composer, along the bottom edge above the keyboard.
///
/// At rest it looks like the bottom bar it replaced: the attachment button
/// beside a field showing the draft's first line, with dictation inside it.
/// Focusing it grows the field's glass into one panel across the width, with
/// the whole draft above a row of the attachment button, dictation and Send.
/// Losing focus, by sending, going back or dragging the keyboard away,
/// collapses it again with the draft kept.
struct PhoneComposer: View {
    @Environment(TaskComposer.self) private var composer
    @Environment(DictationSettings.self) private var dictationSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: HostTask?
    let prompt: String
    /// Sends the draft from the field at the given frame, if known, returning
    /// whether it was sent.
    let submit: (CGRect?) -> Bool

    @State private var editFocusTask: Task<Void, Never>?
    @State private var editorFrame = CGRect.zero

    private var isExpanded: Bool { composer.isFocused }
    private var isSubmittingEdit: Bool { composer.messageEdit?.isSubmitting == true }
    private var showsAttach: Bool { item?.task.actions.contains(.attachImages) != false }
    private var showsCancelEdit: Bool { composer.messageEdit != nil }
    /// At rest, Stop has a button of its own; expanded, Send stands in for it.
    private var showsStop: Bool { item?.task.actions.contains(.interrupt) == true }

    var body: some View {
        @Bindable var composer = composer

        ZStack {
            // The container lets the attachment button's circle melt into
            // the field's glass as it grows.
            GlassEffectContainer(spacing: 0) {
                PhoneComposerLayout(isExpanded: isExpanded, draft: composer.draft) {
                    Color.clear
                        .glassEffect(.regular, in: .rect(cornerRadius: PhoneComposerLayout.cornerRadius))
                        .phoneComposerPart(.panel)

                    if showsAttach {
                        ComposerAttachmentMenu {
                            Label("Attach", systemImage: "plus")
                                .labelStyle(.iconOnly)
                                .font(.title2)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(.circle)
                                .glassEffect(isExpanded ? .identity : .regular.interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .phoneComposerPart(.attach)
                    }

                    if showsCancelEdit {
                        Button("Cancel Edit", systemImage: "xmark") {
                            withAnimation { composer.cancelEdit() }
                        }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.circle)
                        .glassEffect(isExpanded ? .identity : .regular.interactive(), in: .circle)
                        .buttonStyle(.plain)
                        .disabled(isSubmittingEdit)
                        .phoneComposerPart(.cancelEdit)
                    }

                    // Expanded, its circle melts into the panel's end, where
                    // Send stands in for it.
                    if showsStop, let item {
                        Button(role: .destructive) {
                            item.host.interrupt(item.task.id)
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .labelStyle(.iconOnly)
                                .font(.title2)
                                .foregroundStyle(.red)
                                .opacity(isExpanded ? 0 : 1)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.circle)
                        .glassEffect(isExpanded ? .identity : .regular.interactive(), in: .circle)
                        .buttonStyle(.plain)
                        .allowsHitTesting(!isExpanded)
                        .accessibilityHidden(isExpanded)
                        .phoneComposerPart(.stop)
                    }
                }
            }

            // The container draws its glass over everything inside it that
            // isn't glass itself, so the field's contents are laid over it by
            // an identical layout, with empty stand-ins for the buttons above.
            PhoneComposerLayout(isExpanded: isExpanded, draft: composer.draft) {
                if showsAttach { Color.clear.phoneComposerPart(.attach) }
                if showsCancelEdit { Color.clear.phoneComposerPart(.cancelEdit) }
                if showsStop { Color.clear.phoneComposerPart(.stop) }

                ComposerTextView(
                    text: $composer.draft,
                    isFocused: $composer.isFocused,
                    placeholder: composer.messageEdit == nil ? prompt : "Edit message…",
                    isExpanded: isExpanded,
                    isEditable: !isSubmittingEdit,
                    pasteDelegate: composer.pasteDelegate,
                    onReturn: send
                )
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { editorFrame = $0 }
                .phoneComposerPart(.editor)

                if dictationSettings.isEnabled {
                    ComposerDictationButton(composer: composer, isInline: true, symbolScale: .large)
                        .buttonStyle(.plain)
                        .phoneComposerPart(.dictation)
                }

                // Waits hidden at the field's end, so it travels with the
                // field as it grows. Becomes Stop while the agent works with
                // nothing to send.
                PhoneComposerSendButton(item: item, send: send)
                    .scaleEffect(isExpanded ? 1 : 0.5)
                    .opacity(isExpanded ? 1 : 0)
                    .allowsHitTesting(isExpanded)
                    .accessibilityHidden(!isExpanded)
                    .phoneComposerPart(.send)
            }
        }
        .background(ComposerKeyboardAnchor())
        // At rest the bar sits a little into the home indicator's margin, as
        // the system bottom bar does; above the keyboard it keeps clear.
        .padding(.bottom, isExpanded ? PhoneComposerLayout.expandedMargin : -6)
        // The system bottom bar kept the timeline this much further above
        // its items.
        .padding(.top, 10)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4, extraBounce: 0.05), value: isExpanded)
        .animation(.smooth(duration: 0.25), value: composer.draft.isEmpty)
        // A transcript landing in the draft opens it for editing.
        .onChange(of: composer.focusRequestID) { _, id in
            if id != nil { composer.isFocused = true }
        }
        .onChange(of: composer.messageEdit?.id) { _, id in
            editFocusTask?.cancel()
            guard id != nil else { return }
            editFocusTask = Task {
                do { try await Task.sleep(for: TaskComposer.contextMenuDismissalDelay) }
                catch { return }
                composer.isFocused = true
            }
        }
        .onChange(of: composer.editedPromptID) { _, _ in
            composer.isFocused = false
        }
        // Leaving the task can tear the editor down while it still has
        // focus; the next task's first focus must register as a change.
        .onDisappear {
            editFocusTask?.cancel()
            composer.isFocused = false
        }
    }

    /// Sends the draft and, once it's gone, collapses the composer and
    /// closes its keyboard. A draft that couldn't be sent stays open.
    private func send() {
        if submit(editorFrame) {
            composer.isFocused = false
        }
    }
}
