import AtriumClient
import AtriumProtocol
import SwiftUI

/// The task's composer, along the bottom edge above the keyboard, on iPhone
/// and iPad alike, and along the bottom of the Mac's chat.
///
/// At rest it looks like the bottom bar it replaced: the attachment button
/// beside a field showing the draft's first line, with dictation inside it.
/// Focusing it grows the field's glass into one panel across the width, with
/// the whole draft above a row of the attachment button, dictation and Send.
/// Losing focus, by sending, going back or dragging the keyboard away,
/// collapses it again with the draft kept.
///
/// On Mac it stays expanded, and its row also holds the chat's permission
/// menu after the attachment button and its model menu before dictation.
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
    @State private var keyboardCloseTask: Task<Void, Never>?
    @State private var skills: [AgentSkill] = []
    @State private var isLoadingSkills = false
    @State private var skillLoadFailed = false
    @State private var showsSkillPopover = false
    #if os(iOS)
    @State private var menusReady = false
    #endif

    /// Whether the editor has focus. It follows the editor rather than the
    /// request for focus, so the composer only starts to grow or shrink
    /// once UIKit has announced the keyboard moving with it.
    @State private var isEditing = false
    /// Expanded while the editor has focus, and always on Mac.
    private var isExpanded: Bool {
        #if os(macOS)
        true
        #else
        isEditing
        #endif
    }
    private var expandedEditorHeight: CGFloat {
        guard isExpanded, width > 0 else { return 0 }
        return ComposerEditor.expandedHeight(
            of: composer.draft, width: width - ComposerBarLayout.expandedMargin * 2,
            maximumLines: ComposerTextView.maximumLines
        )
    }
    private var isSubmittingEdit: Bool { composer.messageEdit?.isSubmitting == true }
    private var areMenusVisible: Bool {
        #if os(iOS)
        isExpanded && menusReady
        #else
        true
        #endif
    }
    private var showsAttach: Bool { item?.task.actions.contains(.attachImages) != false }
    private var showsCancelEdit: Bool { composer.messageEdit != nil }
    private var action: ComposerBarActionButton.Action {
        composer.sendState(for: item) == .stop ? .stop : .send
    }
    private var skillLoadKey: String {
        guard let item, composer.skillQuery != nil else { return "" }
        return "\(item.host.id)/\(item.task.id)/\(item.task.provider.rawValue)/\(item.task.workspaceID?.uuidString ?? "")"
    }

    var body: some View {
        @Bindable var composer = composer

        VStack(spacing: 0) {
            // What the prompt carries sits above the composer, as it did above
            // the bottom bar.
            if let edit = composer.messageEdit {
                ConversationEditContent(edit: edit)
            }
            if composer.hasAttachments {
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
                            .keyboardShortcut(.cancelAction)
                            .help("Cancel Edit")
                            .disabled(isSubmittingEdit)
                            .composerBarPart(.cancelEdit)
                        }

                        // The resting circle joins the panel's glass. Its
                        // content is drawn above the container so the glass
                        // transition cannot fade the action itself.
                        ComposerBarActionGlass(
                            action: action,
                            isExpanded: isExpanded,
                            isEnabled: action == .stop || (item != nil && composer.canSend),
                            isBusy: composer.sendState(for: item) == .sending
                        )
                        .composerBarPart(.action)
                        #if os(iOS)
                        // Both overlaid layouts must reserve the same menu
                        // row, including when editing at a narrow iPad width.
                        if let item, item.offersComposerMenus {
                            Color.clear
                                .frame(width: ComposerBarLayout.menuControlSize, height: ComposerBarLayout.menuControlSize)
                                .composerBarPart(.model)
                            if item.task.permissionSelection(using: item.host.models(for: item.task.provider)) != nil {
                                Color.clear
                                    .frame(width: ComposerBarLayout.menuControlSize, height: ComposerBarLayout.menuControlSize)
                                    .composerBarPart(.permissions)
                            }
                        }
                        if dictationSettings.isEnabled {
                            Color.clear.frame(width: 44).composerBarPart(.dictation)
                        }
                        #endif
                    }
                }

                // The container draws its glass over everything inside it that
                // isn't glass itself, so the field's contents are laid over it by
                // an identical layout, with empty stand-ins for the buttons above.
                ComposerBarLayout(isExpanded: isExpanded, draft: composer.draft) {
                    if showsAttach { Color.clear.composerBarPart(.attach) }
                    if showsCancelEdit { Color.clear.composerBarPart(.cancelEdit) }

                    ComposerTextView(
                        composer: composer,
                        text: $composer.draft,
                        isFocused: $composer.isFocused,
                        isEditing: $isEditing,
                        placeholder: composer.messageEdit == nil ? prompt : "Edit message…",
                        isExpanded: isExpanded,
                        isEditable: !isSubmittingEdit,
                        pasteDelegate: composer.pasteDelegate,
                        onSkillReturn: {
                            guard composer.skillQuery != nil,
                                  let first = composer.matchingSkills(in: skills).first else { return false }
                            showsSkillPopover = false
                            composer.selectSkill(first)
                            return true
                        },
                        onReturn: send
                    )
                    .popover(isPresented: $showsSkillPopover, arrowEdge: .top) {
                        ComposerSkillSuggestions(
                            matches: composer.matchingSkills(in: skills), hasSkills: !skills.isEmpty,
                            isLoading: isLoadingSkills, failed: skillLoadFailed,
                            select: { skill in
                                showsSkillPopover = false
                                composer.selectSkill(skill)
                                Task {
                                    try? await Task.sleep(for: TaskComposer.contextMenuDismissalDelay)
                                    composer.isFocused = true
                                }
                            }
                        )
                        #if os(iOS)
                        .presentationCompactAdaptation(.popover)
                        #endif
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { editorFrame = $0 }
                    .composerBarPart(.editor)

                    if let item, item.offersComposerMenus {
                        ComposerModelMenu(item: item)
                            .opacity(areMenusVisible ? 1 : 0)
                            .allowsHitTesting(areMenusVisible)
                            .accessibilityHidden(!areMenusVisible)
                            .animation(nil, value: areMenusVisible)
                            .composerBarPart(.model)
                        if let permissions = item.task.permissionSelection(using: item.host.models(for: item.task.provider)) {
                            ComposerPermissionMenu(item: item, selection: permissions)
                                .opacity(areMenusVisible ? 1 : 0)
                                .allowsHitTesting(areMenusVisible)
                                .accessibilityHidden(!areMenusVisible)
                                .animation(nil, value: areMenusVisible)
                                .composerBarPart(.permissions)
                        }
                    }

                    if dictationSettings.isEnabled {
                        ComposerDictationButton(composer: composer, isInline: true, symbolScale: .large)
                            .buttonStyle(.plain)
                            .composerBarPart(.dictation)
                    }

                    // One Button keeps its identity and layout frame in both
                    // composer states, outside Liquid Glass's content animation.
                    ComposerBarActionButton(
                        action: action,
                        isExpanded: isExpanded,
                        isEditing: composer.messageEdit != nil,
                        isEnabled: action == .stop || (item != nil && composer.canSend),
                        isBusy: composer.sendState(for: item) == .sending
                    ) {
                        if action == .send { send() } else if let item { composer.stop(item) }
                    }
                    .composerBarPart(.action)

                }
            }
        }
        #if os(iOS)
        // At rest the bar sits a little into the home indicator's margin, as
        // the system bottom bar does; above the keyboard it keeps clear.
        .padding(.bottom, isExpanded ? ComposerBarLayout.expandedMargin : -6)
        // The system bottom bar kept the timeline this much further above
        // its items.
        .padding(.top, 10)
        // Its top edge is where the timeline's safe area ends.
        .background(ComposerKeyboardAnchor())
        #else
        .padding(.bottom, ComposerBarLayout.expandedMargin)
        .composerFocusRequests()
        #endif
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4, extraBounce: 0.05), value: isExpanded)
        .animation(.smooth(duration: 0.25), value: composer.draft.isEmpty)
        // Each line the draft gains or loses grows or shrinks the panel
        // smoothly, and the timeline follows it.
        .animation(.smooth(duration: 0.25), value: expandedEditorHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .modifier(ComposerHaptics(composer: composer, item: item))
        .task(id: skillLoadKey) {
            guard let item, composer.skillQuery != nil else {
                skills = []
                skillLoadFailed = false
                isLoadingSkills = false
                return
            }
            skills = []
            skillLoadFailed = false
            isLoadingSkills = true
            defer { isLoadingSkills = false }
            do { skills = try await item.host.skills(for: item.task) }
            catch is CancellationError { }
            catch { skillLoadFailed = true }
        }
        .onChange(of: composer.skillQuery) { _, query in
            showsSkillPopover = item != nil && composer.isFocused && query != nil
        }
        .onChange(of: composer.isFocused) { _, focused in
            if focused, item != nil, composer.skillQuery != nil {
                showsSkillPopover = true
            }
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
        #if os(iOS)
        .task(id: isExpanded) {
            menusReady = false
            guard isExpanded else { return }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { menusReady = true }
        }
        .onChange(of: composer.editedPromptID) { _, _ in
            composer.isFocused = false
        }
        #endif
        // Leaving the task can tear the editor down while it still has
        // focus; the next task's first focus must register as a change.
        .onDisappear {
            editFocusTask?.cancel()
            keyboardCloseTask?.cancel()
            composer.isFocused = false
        }
    }

    /// Sends the draft and, once it's gone, collapses the composer and
    /// closes its keyboard. A draft that couldn't be sent stays open.
    private func send() {
        guard submit(editorFrame) else { return }
        #if os(iOS)
        guard isExpanded else {
            composer.isFocused = false
            return
        }
        // Let the prompt begin its flight before closing the keyboard. The
        // same action button then travels with the collapsing composer.
        keyboardCloseTask?.cancel()
        keyboardCloseTask = Task {
            do { try await Task.sleep(for: Self.keyboardCloseDelay) } catch { return }
            composer.isFocused = false
        }
        #endif
    }

    /// About as long as the sent prompt takes to fly up to the top.
    private static let keyboardCloseDelay: Duration = .milliseconds(200)

}
