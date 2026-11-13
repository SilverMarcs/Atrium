import AppKit
import SwiftUI

/// The composer bar's editor: an `NSTextView` that grows with the draft up
/// to `maximumLines`, then scrolls.
///
/// Return adds a line, and ⌘Return sends, unless the hidden
/// `enterToSendChat` default makes Return send; Shift- or Option-Return then
/// add a line.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// Asks for focus, and follows it.
    @Binding var isFocused: Bool
    /// Whether the editor is first responder.
    @Binding var isEditing: Bool
    let placeholder: String
    /// Always true on Mac, where the composer stays expanded.
    let isExpanded: Bool
    let isEditable: Bool
    let pasteDelegate: ComposerPasteDelegate
    let onReturn: () -> Void

    /// The tallest the editor grows before it scrolls.
    static let maximumLines = 16

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, isEditing: $isEditing)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let editor = ComposerEditor()
        editor.delegate = context.coordinator
        editor.string = text
        editor.onFocusChange = { [coordinator = context.coordinator] focused in coordinator.focusDidChange(focused) }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        // The editor reaches the panel's top corners; its scroller keeps
        // inside their curve.
        scrollView.scrollerInsets = NSEdgeInsets(top: 10, left: 0, bottom: 2, right: 6)
        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? ComposerEditor else { return }
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        context.coordinator.isEditing = $isEditing
        editor.onReturn = onReturn
        editor.pasteDelegate = pasteDelegate
        editor.placeholder = placeholder
        editor.isEditable = isEditable
        // Leave text being composed with marked text alone; replacing it
        // would end the composition.
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.needsDisplay = true
        }
        // Focus changes from outside AppKit land after this update, so they
        // don't run inside SwiftUI's view update.
        if isFocused != editor.isFirstResponder {
            Task { @MainActor [weak editor] in
                guard let editor, let window = editor.window, isFocused != editor.isFirstResponder else { return }
                if isFocused {
                    window.makeFirstResponder(editor)
                } else {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }

    /// Exactly the room `ComposerBarLayout` gives it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var isEditing: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>, isEditing: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
            self.isEditing = isEditing
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ComposerEditor else { return }
            editor.needsDisplay = true
            if text.wrappedValue != editor.string {
                text.wrappedValue = editor.string
            }
        }

        func focusDidChange(_ focused: Bool) {
            if isEditing.wrappedValue != focused { isEditing.wrappedValue = focused }
            if isFocused.wrappedValue != focused { isFocused.wrappedValue = focused }
        }
    }
}

/// The text view behind `ComposerTextView`, with a placeholder, attachment
/// pasting and Return-to-send.
final class ComposerEditor: NSTextView {
    var onReturn: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    weak var pasteDelegate: ComposerPasteDelegate?

    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }

    /// The text's distance from the editor's sides, as on iPhone and iPad.
    static let horizontalInset: CGFloat = 20
    /// Above the first line, and below the last, which sits just over the
    /// composer's button row.
    static let insets = (top: CGFloat(14), bottom: CGFloat(4))

    private static var font: NSFont { .preferredFont(forTextStyle: .body) }

    convenience init() {
        self.init(frame: .zero)
        configure()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        drawsBackground = false
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = false
        usesFindPanel = false
        isIncrementalSearchingEnabled = false
        isContinuousSpellCheckingEnabled = true
        font = Self.font
        textColor = .labelColor
        typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        // The insets split between top and bottom; `textContainerOrigin`
        // puts the larger one on top.
        textContainerInset = NSSize(width: Self.horizontalInset, height: (Self.insets.top + Self.insets.bottom) / 2)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        setAccessibilityIdentifier("composer")
        // Images and files dropped on the editor go to the composer's drop
        // handler, which attaches them, rather than in as their paths.
        unregisterDraggedTypes()
        registerForDraggedTypes([.string])
    }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: Self.horizontalInset, y: Self.insets.top)
    }

    var isFirstResponder: Bool { window?.firstResponder === self }

    // MARK: - Measuring

    /// The editor's height at this width for `text`: its wrapped lines, from
    /// one up to `maximumLines`, measured as the editor lays them out.
    ///
    /// Both of the composer's layouts ask for it on every pass, many times
    /// a frame while the composer resizes, so the last answer is kept.
    static func expandedHeight(of text: String, width: CGFloat, maximumLines: Int) -> CGFloat {
        let font = font
        let key = Measurement(text: text, width: width, maximumLines: maximumLines, fontSize: font.pointSize)
        if let lastMeasurement, lastMeasurement.key == key { return lastMeasurement.height }
        let editor = measuringEditor
        editor.font = font
        editor.setFrameSize(NSSize(width: max(width, horizontalInset * 2 + 1), height: 0))
        let oneLine = oneLineHeight(of: editor, key: key)
        editor.string = text
        let height = text.isEmpty ? oneLine : editor.fittingHeight
        let verticalInsets = insets.top + insets.bottom
        let maximum = verticalInsets + (oneLine - verticalInsets) * CGFloat(maximumLines)
        let result = ceil(min(max(height, oneLine), maximum))
        lastMeasurement = (key, result)
        return result
    }

    private struct Measurement: Equatable {
        var text: String
        var width: CGFloat
        var maximumLines: Int
        var fontSize: CGFloat
    }

    private static var lastMeasurement: (key: Measurement, height: CGFloat)?
    /// One line's height at a width and text size, which only changes with them.
    private static var lastOneLine: (width: CGFloat, fontSize: CGFloat, height: CGFloat)?

    private static func oneLineHeight(of editor: ComposerEditor, key: Measurement) -> CGFloat {
        if let lastOneLine, lastOneLine.width == key.width, lastOneLine.fontSize == key.fontSize {
            return lastOneLine.height
        }
        // An empty draft's line lays out a point taller than one with text.
        editor.string = ""
        let empty = editor.fittingHeight
        editor.string = " "
        let height = max(editor.fittingHeight, empty)
        lastOneLine = (key.width, key.fontSize, height)
        return height
    }

    private static let measuringEditor = ComposerEditor()

    /// The height the text takes at the editor's width, with its insets.
    private var fittingHeight: CGFloat {
        guard let textContainer else { return 0 }
        let used: CGFloat
        if let textLayoutManager {
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
            used = textLayoutManager.usageBoundsForTextContainer.height
        } else if let layoutManager {
            layoutManager.ensureLayout(for: textContainer)
            used = layoutManager.usedRect(for: textContainer).height
        } else {
            used = 0
        }
        return used + Self.insets.top + Self.insets.bottom
    }

    // MARK: - Layout

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        fillClipView()
    }

    /// Fills the scroll view even while the draft is shorter, so a click
    /// anywhere in the editor places the caret.
    func fillClipView() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsFrameChangedNotifications = true
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewFrameDidChange), name: NSView.frameDidChangeNotification, object: clipView
        )
        clipViewFrameDidChange()
    }

    @objc private func clipViewFrameDidChange() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        minSize = NSSize(width: 0, height: clipView.bounds.height)
        if frame.width != clipView.bounds.width || frame.height < clipView.bounds.height {
            setFrameSize(NSSize(width: clipView.bounds.width, height: max(frame.height, clipView.bounds.height)))
        }
        sizeToFit()
    }

    // MARK: - Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Self.font,
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = textContainerOrigin
        let rect = NSRect(x: origin.x, y: origin.y, width: max(bounds.width - origin.x * 2, 0), height: bounds.height - origin.y)
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    // MARK: - Paste

    override func paste(_ sender: Any?) {
        if pasteDelegate?.paste(from: .general, into: self) == true { return }
        super.paste(sender)
    }

    // MARK: - Return

    override func insertNewline(_ sender: Any?) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if UserDefaults.standard.bool(forKey: "enterToSendChat"),
           modifiers.isDisjoint(with: [.shift, .option, .command]) {
            onReturn?()
            return
        }
        super.insertNewline(sender)
    }
}
