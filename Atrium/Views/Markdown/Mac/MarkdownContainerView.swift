import AppKit

final class MarkdownContainerView: NSView {
    private enum Layout {
        static let copyButtonInset: CGFloat = 4
        static let copyButtonSize: CGFloat = 23
    }

    private let textView = MarkdownPlainTextView()
    private var currentWidth: CGFloat = 0
    private var lastReportedHeight: CGFloat = 0
    private var lastMeasuredSize: CGSize = .zero
    private var currentDocument: MarkdownRenderedDocument?
    private var currentRequest: MarkdownRenderRequest?
    private var currentThemeName: String?
    private var isShowingPlaceholder = false
    private var isShowingStreamedContent = false
    private var needsMeasurement = false
    private var codeBlockButtons: [Int: NSButton] = [:]
    private var cachedCodeBlockFrames: [(codeBlock: MarkdownCodeBlock, frame: NSRect)] = []
    private var hoveredCodeBlockID: Int?
    private var trackingArea: NSTrackingArea?
    var onThemeChange: ((String) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    private var widthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.textContainerInset = .zero
        textView.markdownTextContainer.lineFragmentPadding = 0
        textView.markdownTextContainer.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textView)

        let widthConstraint = textView.widthAnchor.constraint(equalToConstant: 0)
        self.widthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()

        let themeName = colorSchemeThemeName
        guard currentThemeName != themeName else { return }
        currentThemeName = themeName
        updateAppearance()
        onThemeChange?(themeName)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoveredCodeBlock(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredCodeBlockID = nil
        updateCopyButtonVisibility()
    }

    override func layout() {
        super.layout()

        let width = bounds.width > 0 ? bounds.width : currentWidth
        guard width > 0 else { return }

        recalculateIfNeeded(for: width, reportHeight: true)
        layoutCodeBlockButtons()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: lastMeasuredSize.width, height: lastMeasuredSize.height)
    }

    var activeThemeName: String {
        currentThemeName ?? colorSchemeThemeName
    }

    func showPlaceholder(text: String, fontSize: CGFloat, for request: MarkdownRenderRequest) {
        currentThemeName = request.themeName
        updateAppearance()

        guard currentRequest != request || !isShowingPlaceholder else {
            recalculateIfNeeded(for: currentWidth, reportHeight: true)
            return
        }

        currentRequest = request
        currentDocument = nil
        isShowingPlaceholder = true
        display(document: .placeholder(text: text, fontSize: fontSize))
    }

    func apply(document: MarkdownRenderedDocument, for request: MarkdownRenderRequest, isStreamed: Bool = false) {
        currentThemeName = request.themeName
        updateAppearance()

        guard currentRequest != request || isShowingPlaceholder || currentDocument == nil || isShowingStreamedContent else {
            recalculateIfNeeded(for: currentWidth, reportHeight: true)
            return
        }

        currentRequest = request
        currentDocument = document
        isShowingPlaceholder = false
        isShowingStreamedContent = isStreamed
        display(document: document)
    }

    func measuredSize(for width: CGFloat) -> CGSize {
        recalculateIfNeeded(for: width, reportHeight: false)
        return lastMeasuredSize
    }

    private func display(document: MarkdownRenderedDocument) {
        textView.update(document: document)
        syncCodeBlockButtons(with: document.codeBlocks)
        needsMeasurement = true
        needsLayout = true
        invalidateIntrinsicContentSize()
        recalculateIfNeeded(for: currentWidth, reportHeight: true)
    }

    private func updateAppearance() {
        textView.needsDisplay = true
    }

    private func recalculateIfNeeded(for width: CGFloat, reportHeight: Bool) {
        let resolvedWidth = ceil(width)
        guard resolvedWidth > 0 else { return }

        currentWidth = resolvedWidth

        guard needsMeasurement || lastMeasuredSize.width != resolvedWidth else {
            if reportHeight {
                reportHeightIfNeeded(lastMeasuredSize.height)
            }
            return
        }

        widthConstraint?.constant = resolvedWidth
        let measuredHeight = measureHeight()
        lastMeasuredSize = CGSize(width: resolvedWidth, height: measuredHeight)
        needsMeasurement = false

        if reportHeight {
            reportHeightIfNeeded(measuredHeight)
        }
    }

    private func measureHeight() -> CGFloat {
        guard currentWidth > 0 else { return 0 }

        textView.frame.size.width = currentWidth
        textView.markdownTextContainer.containerSize = CGSize(
            width: currentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.markdownLayoutManager.ensureLayout(for: textView.markdownTextContainer)
        let usedRect = textView.markdownLayoutManager.usedRect(for: textView.markdownTextContainer)
        return ceil(usedRect.height)
    }

    private func reportHeightIfNeeded(_ measuredHeight: CGFloat) {
        guard measuredHeight > 0, measuredHeight != lastReportedHeight else { return }

        lastReportedHeight = measuredHeight
        onHeightChange?(measuredHeight)
    }

    private func syncCodeBlockButtons(with codeBlocks: [MarkdownCodeBlock]) {
        let nextIDs = Set(codeBlocks.map(\.id))

        for id in codeBlockButtons.keys where !nextIDs.contains(id) {
            codeBlockButtons[id]?.removeFromSuperview()
            codeBlockButtons[id] = nil
        }

        for codeBlock in codeBlocks where codeBlockButtons[codeBlock.id] == nil {
            let button = NSButton(
                image: NSImage(
                    systemSymbolName: "clipboard",
                    accessibilityDescription: "Copy code"
                ) ?? NSImage(),
                target: self,
                action: #selector(copyCodeBlock(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier(String(codeBlock.id))
            button.imagePosition = .imageOnly
            button.bezelStyle = .regularSquare
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = true
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            addSubview(button)
            codeBlockButtons[codeBlock.id] = button
        }
    }

    private func layoutCodeBlockButtons() {
        cachedCodeBlockFrames = textView.codeBlockFrames()
        let codeBlockRects = Dictionary(
            uniqueKeysWithValues: cachedCodeBlockFrames.map { ($0.codeBlock.id, $0.frame) }
        )

        for (id, button) in codeBlockButtons {
            guard let codeBlockRect = codeBlockRects[id] else {
                button.isHidden = true
                continue
            }

            let convertedRect = textView.convert(codeBlockRect, to: self)
            button.frame = NSRect(
                x: convertedRect.maxX - Layout.copyButtonSize - Layout.copyButtonInset,
                y: convertedRect.minY + Layout.copyButtonInset,
                width: Layout.copyButtonSize,
                height: Layout.copyButtonSize
            ).integral
        }

        updateCopyButtonVisibility()
    }

    private func updateHoveredCodeBlock(for event: NSEvent) {
        let locationInTextView = textView.convert(event.locationInWindow, from: nil)
        var newHoveredID: Int?

        for (codeBlock, frame) in cachedCodeBlockFrames {
            if frame.contains(locationInTextView) {
                newHoveredID = codeBlock.id
                break
            }
        }

        guard hoveredCodeBlockID != newHoveredID else { return }
        hoveredCodeBlockID = newHoveredID
        updateCopyButtonVisibility()
    }

    private func updateCopyButtonVisibility() {
        for (id, button) in codeBlockButtons {
            button.isHidden = id != hoveredCodeBlockID
        }
    }

    @objc
    private func copyCodeBlock(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let codeBlockID = Int(identifier),
              let codeBlock = currentDocument?.codeBlocks.first(where: { $0.id == codeBlockID }) else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(codeBlock.content, forType: .string)
    }

    private var colorSchemeThemeName: String {
        switch effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua:
            "atom-one-dark"
        default:
            "atom-one-light"
        }
    }

}

func markdownAncestorMenu(from view: NSView) -> NSMenu? {
    var currentView = unsafe view.superview

    while let candidate = currentView {
        if let menu = candidate.menu {
            return menu
        }

        currentView = unsafe candidate.superview
    }

    return nil
}
