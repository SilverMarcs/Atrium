import AtriumClient
import AtriumProtocol
import SwiftUI

/// The task's composer, along the bottom edge above the keyboard, on iPhone
/// and iPad alike.
///
/// At rest it looks like the bottom bar it replaced: the attachment button
/// beside a field showing the draft's first line, with dictation inside it.
/// Focusing it grows the field's glass into one panel across the width, with
/// the whole draft above a row of the attachment button, dictation and Send.
/// Losing focus, by sending, going back or dragging the keyboard away,
/// collapses it again with the draft kept.
struct ComposerBar: View {
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
    @State private var width: CGFloat = 0
    /// After a send, the resting circle (Stop, or none, as the draft has
    /// gone) shows once the composer has dropped back into place, rather
    /// than riding down from the panel's end. Otherwise it melts out of the
    /// panel as it collapses.
    @State private var showsRestingAction = true
    @State private var revealTask: Task<Void, Never>?

    /// Expanded while the editor has focus. It follows the editor rather
    /// than the request for focus, so the composer only starts to grow or
    /// shrink once UIKit has announced the keyboard moving with it.
    @State private var isExpanded = false
    private var expandedEditorHeight: CGFloat {
        guard isExpanded, width > 0 else { return 0 }
        return ComposerEditor.expandedHeight(
            of: composer.draft, width: width - ComposerBarLayout.expandedMargin * 2,
            maximumLines: ComposerTextView.maximumLines
        )
    }
    private var isSubmittingEdit: Bool { composer.messageEdit?.isSubmitting == true }
    private var showsAttach: Bool { item?.task.actions.contains(.attachImages) != false }
    private var showsCancelEdit: Bool { composer.messageEdit != nil }
    /// At rest, Send has a circle of its own once there's something to send,
    /// as Stop does while the agent works; expanded, the panel's Send button
    /// stands in for both.
    private var restingAction: ComposerBarActionButton.Action? {
        if let item, composer.offersStop(for: item.task.actions) { return .stop }
        // Dictating shows Send only once the recording has become text.
        if composer.hasContent { return .send }
        if item?.task.actions.contains(.interrupt) == true { return .stop }
        return nil
    }

    var body: some View {
        @Bindable var composer = composer

        VStack(spacing: 0) {
            // What the prompt carries sits above the composer, as it did above
            // the bottom bar.
            if let edit = composer.messageEdit {
                ConversationEditContent(edit: edit)
            }
            if !composer.images.isEmpty {
                ComposerAttachmentStrip(composer: composer)
            }

            ZStack {
                // The container lets the attachment button's circle melt into
                // the field's glass as it grows.
                GlassEffectContainer(spacing: 0) {
                    ComposerBarLayout(isExpanded: isExpanded, draft: composer.draft) {
                        Color.clear
                            .glassEffect(.regular, in: .rect(cornerRadius: ComposerBarLayout.cornerRadius))
                            .composerBarPart(.panel)

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
                            .composerBarPart(.attach)
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
                            .composerBarPart(.cancelEdit)
                        }

                        // Expanded, its circle melts into the panel's end, where
                        // Send stands in for it.
                        if let action = restingAction {
                            ComposerBarActionButton(
                                action: action,
                                isEditing: composer.messageEdit != nil,
                                isEnabled: action == .stop || composer.canSend,
                                isHidden: isExpanded || !showsRestingAction
                            ) {
                                if action == .send { send() } else if let item { item.host.interrupt(item.task.id) }
                            }
                            .composerBarPart(.action)
                        }
                    }
                }

                // The container draws its glass over everything inside it that
                // isn't glass itself, so the field's contents are laid over it by
                // an identical layout, with empty stand-ins for the buttons above.
                ComposerBarLayout(isExpanded: isExpanded, draft: composer.draft) {
                    if showsAttach { Color.clear.composerBarPart(.attach) }
                    if showsCancelEdit { Color.clear.composerBarPart(.cancelEdit) }
                    if restingAction != nil { Color.clear.composerBarPart(.action) }

                    ComposerTextView(
                        text: $composer.draft,
                        isFocused: $composer.isFocused,
                        isEditing: $isExpanded,
                        placeholder: composer.messageEdit == nil ? prompt : "Edit message…",
                        isExpanded: isExpanded,
                        isEditable: !isSubmittingEdit,
                        pasteDelegate: composer.pasteDelegate,
                        onReturn: send
                    )
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { editorFrame = $0 }
                    .composerBarPart(.editor)

                    if dictationSettings.isEnabled {
                        ComposerDictationButton(composer: composer, isInline: true, symbolScale: .large)
                            .buttonStyle(.plain)
                            .composerBarPart(.dictation)
                    }

                    // Waits hidden at the field's end, so it travels with the
                    // field as it grows. Becomes Stop while the agent works with
                    // nothing to send.
                    ComposerBarSendButton(item: item, send: send)
                        .scaleEffect(isExpanded ? 1 : 0.5)
                        .opacity(isExpanded ? 1 : 0)
                        // Gone as soon as the panel starts to drop.
                        .animation(isExpanded ? .easeOut(duration: 0.12) : nil, value: isExpanded)
                        .allowsHitTesting(isExpanded)
                        .accessibilityHidden(!isExpanded)
                        .composerBarPart(.send)
                }
            }
            // At rest the bar sits a little into the home indicator's margin, as
            // the system bottom bar does; above the keyboard it keeps clear.
        }
        .padding(.bottom, isExpanded ? ComposerBarLayout.expandedMargin : -6)
        // The system bottom bar kept the timeline this much further above
        // its items.
        .padding(.top, 10)
        // Its top edge is where the timeline's safe area ends.
        .background(ComposerKeyboardAnchor())
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4, extraBounce: 0.05), value: isExpanded)
        .animation(.smooth(duration: 0.25), value: composer.draft.isEmpty)
        // Each line the draft gains or loses grows or shrinks the panel
        // smoothly, and the timeline follows it.
        .animation(.smooth(duration: 0.25), value: expandedEditorHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(.smooth(duration: 0.25), value: restingAction)
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
            revealTask?.cancel()
            showsRestingAction = true
            composer.isFocused = false
        }
    }

    /// Sends the draft and, once it's gone, collapses the composer and
    /// closes its keyboard. A draft that couldn't be sent stays open.
    private func send() {
        guard submit(editorFrame) else { return }
        if isExpanded {
            showsRestingAction = false
            revealTask?.cancel()
            revealTask = Task {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                withAnimation(.smooth(duration: 0.3)) { showsRestingAction = true }
            }
        }
        composer.isFocused = false
        // Closes the keyboard in this turn, rather than after SwiftUI's next
        // update reaches the editor.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
