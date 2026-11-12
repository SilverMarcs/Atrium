import SwiftUI

/// The composer bar's editor: a `UITextView` that shows the draft's first
/// line at rest and grows with the draft while it's being written.
///
/// The keyboard's Return adds a line. A hardware keyboard's Return sends,
/// and Shift- or Option-Return adds a line.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    /// Asks for focus, and follows it.
    @Binding var isFocused: Bool
    /// Whether the editor is first responder: set only once UIKit has moved
    /// focus, after the keyboard's own announcements.
    @Binding var isEditing: Bool
    let placeholder: String
    /// Whether the editor shows the whole draft, rather than its first line.
    let isExpanded: Bool
    let isEditable: Bool
    let pasteDelegate: ComposerPasteDelegate
    let onReturn: () -> Void

    /// The tallest the editor grows before it scrolls.
    static let maximumLines = 8

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, isEditing: $isEditing)
    }

    func makeUIView(context: Context) -> ComposerEditor {
        let editor = ComposerEditor()
        editor.delegate = context.coordinator
        editor.text = text
        pasteDelegate.configure(editor)
        return editor
    }

    func updateUIView(_ editor: ComposerEditor, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        context.coordinator.isEditing = $isEditing
        editor.onReturn = onReturn
        editor.placeholder = placeholder
        editor.isEditable = isEditable
        editor.isExpanded = isExpanded
        // Leave text being composed with marked text alone; replacing it
        // would end the composition.
        if editor.text != text, editor.markedTextRange == nil {
            editor.text = text
            editor.textDidChange()
        }
        // Focus changes from outside UIKit land after this update, so they
        // don't run inside SwiftUI's view update.
        if isFocused != editor.isFirstResponder {
            Task { @MainActor [weak editor] in
                guard let editor, editor.window != nil, isFocused != editor.isFirstResponder else { return }
                if isFocused { editor.focus() } else { editor.resignFirstResponder() }
            }
        }
    }

    /// Exactly the room `ComposerBarLayout` gives it, rather than the
    /// draft's unwrapped width UIKit would ask for.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView editor: ComposerEditor, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var isEditing: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>, isEditing: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
            self.isEditing = isEditing
        }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? ComposerEditor)?.textDidChange()
            if text.wrappedValue != textView.text {
                text.wrappedValue = textView.text
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing.wrappedValue = true
            if !isFocused.wrappedValue { isFocused.wrappedValue = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing.wrappedValue = false
            if isFocused.wrappedValue { isFocused.wrappedValue = false }
        }
    }
}

/// The text view behind `ComposerTextView`, with a placeholder, a single
/// truncated line at rest, and Return-to-send on hardware keyboards.
final class ComposerEditor: UITextView {
    var onReturn: (() -> Void)?

    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            placeholderLabel.text = placeholder
            accessibilityLabel = placeholder
        }
    }

    var isExpanded = false {
        didSet {
            guard isExpanded != oldValue else { return }
            applyMode()
        }
    }

    /// The text's distance from the editor's sides, as in the field it replaced.
    static let horizontalInset: CGFloat = 20
    /// Above the first line once expanded, and below the last, which sits
    /// just over the composer's button row.
    static let expandedInsets = (top: CGFloat(14), bottom: CGFloat(4))

    private let placeholderLabel = UILabel()

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        textContainer.lineFragmentPadding = 0
        returnKeyType = .default
        autocapitalizationType = .sentences
        autocorrectionType = .yes
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        // It sits on the bottom safe area's edge, which would otherwise inset
        // and shift its text.
        contentInsetAdjustmentBehavior = .never
        accessibilityIdentifier = "composer"

        placeholderLabel.font = font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        // A search field's prompt color, which is dimmer than secondary
        // text in Dark Mode.
        placeholderLabel.textColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.38)
                : .secondaryLabel
        }
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (editor: ComposerEditor, _: UITraitCollection) in
            editor.setNeedsLayout()
            editor.invalidateIntrinsicContentSize()
        }
        applyMode()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Posted, with the editor, just before a change to the draft makes
    /// the expanded composer grow or shrink, so the timeline can follow it.
    static let willResizeNotification = Notification.Name("ComposerEditor.willResize")

    /// The height the expanded editor is growing or shrinking to.
    private var targetHeight: CGFloat = 0

    func textDidChange() {
        placeholderLabel.isHidden = !text.isEmpty
        if isExpanded, bounds.width > 0 {
            let height = Self.expandedHeight(of: text, width: bounds.width, maximumLines: ComposerTextView.maximumLines)
            if height != targetHeight {
                targetHeight = height
                NotificationCenter.default.post(name: Self.willResizeNotification, object: self)
            }
        }
        updateScrolling()
    }

    /// At rest the editor shows the draft's first line, truncated, centered
    /// in the field. Expanded it wraps the whole draft from the top.
    private func applyMode() {
        textContainer.maximumNumberOfLines = isExpanded ? 0 : 1
        textContainer.lineBreakMode = isExpanded ? .byWordWrapping : .byTruncatingTail
        // Expanded, it always scrolls, so UIKit keeps the caret in view
        // once the draft outgrows it.
        isScrollEnabled = isExpanded
        contentOffset = .zero
        targetHeight = 0
        setNeedsLayout()
        if isExpanded {
            // Opening a long draft shows where the caret is, once laid out.
            Task { @MainActor [weak self] in
                guard let self, self.isExpanded else { return }
                self.layoutIfNeeded()
                self.scrollRangeToVisible(self.selectedRange)
            }
        }
    }

    /// The editor's expanded height at this width for `text`: its wrapped
    /// lines, from one up to `maximumLines`, measured as the editor lays
    /// them out.
    static func expandedHeight(of text: String, width: CGFloat, maximumLines: Int) -> CGFloat {
        let editor = measuringEditor
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textContainerInset = UIEdgeInsets(top: expandedInsets.top, left: horizontalInset,
                                                 bottom: expandedInsets.bottom, right: horizontalInset)
        let fitting = CGSize(width: max(width, horizontalInset * 2 + 1), height: .greatestFiniteMagnitude)
        editor.text = " "
        let oneLine = editor.sizeThatFits(fitting).height
        editor.text = text
        let height = text.isEmpty ? oneLine : editor.sizeThatFits(fitting).height
        let insets = expandedInsets.top + expandedInsets.bottom
        let maximum = insets + (oneLine - insets) * CGFloat(maximumLines)
        return ceil(min(max(height, oneLine), maximum))
    }

    private static let measuringEditor: ComposerEditor = {
        let editor = ComposerEditor()
        editor.isExpanded = true
        return editor
    }()

    private var lineHeight: CGFloat {
        (font ?? .preferredFont(forTextStyle: .body)).lineHeight
    }

    override func layoutSubviews() {
        let insets: UIEdgeInsets
        if isExpanded {
            insets = UIEdgeInsets(top: Self.expandedInsets.top, left: Self.horizontalInset,
                                  bottom: Self.expandedInsets.bottom, right: Self.horizontalInset)
        } else {
            let vertical = max((bounds.height - lineHeight) / 2, 0)
            insets = UIEdgeInsets(top: vertical, left: Self.horizontalInset, bottom: vertical, right: Self.horizontalInset)
        }
        if textContainerInset != insets {
            textContainerInset = insets
        }
        super.layoutSubviews()
        placeholderLabel.font = font
        placeholderLabel.frame = CGRect(
            x: insets.left, y: insets.top,
            width: max(bounds.width - insets.left - insets.right, 0), height: lineHeight
        )
        updateScrolling()
    }

    /// Scrolls only once the draft is taller than the editor can grow.
    /// A new line scrolls to the caret before the editor has grown to fit
    /// it; once the draft fits, its first line goes back to the top.
    ///
    /// While the editor grows to fit, it stays at the top rather than
    /// scrolling to the new line it hasn't grown to show yet.
    private func updateScrolling() {
        guard isExpanded, contentSize.height <= max(bounds.height, targetHeight) + 0.5, contentOffset.y != 0 else { return }
        contentOffset = .zero
    }

    // MARK: - Focus

    /// Until when the editor may take focus. UIKit hands focus back to the
    /// editor that last had it whenever its screen reappears, which would
    /// open the composer on returning to a task; only a touch, VoiceOver or
    /// a request from the composer opens it.
    private var focusAllowedUntil: CFTimeInterval = 0

    func focus() {
        focusAllowedUntil = CACurrentMediaTime() + 1
        becomeFirstResponder()
    }

    /// Leaving ends the window a touch opened, so nothing hands focus back
    /// straight after a send.
    override func resignFirstResponder() -> Bool {
        focusAllowedUntil = 0
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        guard CACurrentMediaTime() < focusAllowedUntil else { return false }
        return super.becomeFirstResponder()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        if view != nil, event?.type == .touches {
            focusAllowedUntil = CACurrentMediaTime() + 2
        }
        return view
    }

    override func accessibilityActivate() -> Bool {
        focusAllowedUntil = CACurrentMediaTime() + 1
        return super.accessibilityActivate()
    }

    // MARK: - Hardware Return

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if sendsOnReturn(presses) {
            onReturn?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !sendsOnReturn(presses) else { return }
        super.pressesEnded(presses, with: event)
    }

    /// Return on its own, outside a composition such as Japanese input.
    private func sendsOnReturn(_ presses: Set<UIPress>) -> Bool {
        guard markedTextRange == nil, presses.count == 1, let key = presses.first?.key,
              key.keyCode == .keyboardReturnOrEnter else { return false }
        return key.modifierFlags.isDisjoint(with: [.shift, .alternate, .command, .control])
    }
}
