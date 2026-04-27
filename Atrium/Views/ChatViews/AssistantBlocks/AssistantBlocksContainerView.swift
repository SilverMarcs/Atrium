import AppKit

final class AssistantBlocksContainerView: NSView {
    private enum Layout {
        static let copyButtonInset: CGFloat = 4
        static let copyButtonSize: CGFloat = 23
    }

    private let textView = AssistantBlocksTextView()
    private var widthConstraint: NSLayoutConstraint?

    private var currentWidth: CGFloat = 0
    private var lastReportedHeight: CGFloat = 0
    private var lastMeasuredSize: CGSize = .zero
    private var currentDocument: AssistantBlocksDocument?
    private var currentThemeName: String?
    private var needsMeasurement = false
    private var hasAppliedDocument = false

    // Code block copy buttons
    private var codeBlockButtons: [Int: NSButton] = [:]
    private var cachedCodeBlockFrames: [(codeBlock: MarkdownCodeBlock, frame: NSRect)] = []
    private var hoveredCodeBlockID: Int?
    private var trackingArea: NSTrackingArea?

    // Diff overlays
    private var diffOverlayViews: [Int: DiffOverlayView] = [:]

    // Tool call popover
    private var toolCallPopover: NSPopover?

    var onHeightChange: ((CGFloat) -> Void)?
    var onThemeChange: ((String) -> Void)?
    var onOpenFile: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.textContainerInset = .zero
        textView.blocksTextContainer.lineFragmentPadding = 0
        textView.blocksTextContainer.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.onToolCallClick = { [weak self] groupID, rect in
            self?.showToolCallPopover(groupID: groupID, anchorRect: rect)
        }

        addSubview(textView)

        let wc = textView.widthAnchor.constraint(equalToConstant: 0)
        widthConstraint = wc
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            wc
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
        textView.needsDisplay = true
        for view in diffOverlayViews.values {
            view.refreshAppearance()
        }
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
        layoutDiffOverlays()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: lastMeasuredSize.width, height: lastMeasuredSize.height)
    }

    var activeThemeName: String {
        currentThemeName ?? colorSchemeThemeName
    }

    func apply(document: AssistantBlocksDocument) {
        hasAppliedDocument = true
        currentThemeName = colorSchemeThemeName
        currentDocument = document

        textView.blocksLayoutManager.codeBlocks = document.codeBlocks
        textView.blocksLayoutManager.quoteBlocks = document.quoteBlocks
        textView.blocksLayoutManager.tableBlocks = document.tableBlocks
        textView.blocksLayoutManager.hasThematicBreaks = document.hasThematicBreaks
        textView.blocksTextStorage.setAttributedString(document.attributedString)

        syncCodeBlockButtons(with: document.codeBlocks)
        syncDiffOverlays(with: document.diffOverlays)

        needsMeasurement = true
        needsLayout = true
        invalidateIntrinsicContentSize()
        recalculateIfNeeded(for: currentWidth, reportHeight: true)
    }

    func measuredSize(for width: CGFloat) -> CGSize {
        recalculateIfNeeded(for: width, reportHeight: false)
        return lastMeasuredSize
    }

    // MARK: - Measurement

    private func recalculateIfNeeded(for width: CGFloat, reportHeight: Bool) {
        let resolvedWidth = ceil(width)
        guard resolvedWidth > 0 else { return }

        currentWidth = resolvedWidth

        guard needsMeasurement || lastMeasuredSize.width != resolvedWidth else {
            if reportHeight { reportHeightIfNeeded(lastMeasuredSize.height) }
            return
        }

        widthConstraint?.constant = resolvedWidth
        let measuredHeight = measureHeight()
        lastMeasuredSize = CGSize(width: resolvedWidth, height: measuredHeight)
        needsMeasurement = false

        if reportHeight { reportHeightIfNeeded(measuredHeight) }
    }

    private func measureHeight() -> CGFloat {
        guard currentWidth > 0 else { return 0 }
        textView.frame.size.width = currentWidth
        textView.blocksTextContainer.containerSize = CGSize(
            width: currentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.blocksLayoutManager.ensureLayout(for: textView.blocksTextContainer)
        let usedRect = textView.blocksLayoutManager.usedRect(for: textView.blocksTextContainer)
        return ceil(usedRect.height)
    }

    private func reportHeightIfNeeded(_ measuredHeight: CGFloat) {
        guard hasAppliedDocument, measuredHeight > 0, measuredHeight != lastReportedHeight else { return }
        lastReportedHeight = measuredHeight
        onHeightChange?(measuredHeight)
    }

    // MARK: - Code blocks (copy buttons)

    private func syncCodeBlockButtons(with codeBlocks: [MarkdownCodeBlock]) {
        let nextIDs = Set(codeBlocks.map(\.id))
        for id in codeBlockButtons.keys where !nextIDs.contains(id) {
            codeBlockButtons[id]?.removeFromSuperview()
            codeBlockButtons[id] = nil
        }
        for codeBlock in codeBlocks where codeBlockButtons[codeBlock.id] == nil {
            let button = NSButton(
                image: NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Copy code") ?? NSImage(),
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
        cachedCodeBlockFrames = textView.blocksLayoutManager.codeBlockFrames(in: textView.blocksTextContainer)
        let codeBlockRects = Dictionary(uniqueKeysWithValues: cachedCodeBlockFrames.map { ($0.codeBlock.id, $0.frame) })

        for (id, button) in codeBlockButtons {
            guard let rect = codeBlockRects[id] else {
                button.isHidden = true
                continue
            }
            let convertedRect = textView.convert(rect, to: self)
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

    // MARK: - Diff overlays

    private func syncDiffOverlays(with specs: [DiffOverlaySpec]) {
        let nextIDs = Set(specs.map(\.id))
        for id in diffOverlayViews.keys where !nextIDs.contains(id) {
            diffOverlayViews[id]?.removeFromSuperview()
            diffOverlayViews[id] = nil
        }
        for spec in specs {
            if let existing = diffOverlayViews[spec.id] {
                existing.configure(spec: spec)
            } else {
                let view = DiffOverlayView()
                view.translatesAutoresizingMaskIntoConstraints = true
                view.onOpenFile = { [weak self] path in
                    self?.onOpenFile?(path)
                }
                view.configure(spec: spec)
                addSubview(view)
                diffOverlayViews[spec.id] = view
            }
        }
    }

    private func layoutDiffOverlays() {
        guard let document = currentDocument else { return }

        let layoutManager = textView.blocksLayoutManager
        let container = textView.blocksTextContainer

        for spec in document.diffOverlays {
            guard let view = diffOverlayViews[spec.id] else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: spec.range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else {
                view.isHidden = true
                continue
            }
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let converted = textView.convert(rect, to: self)
            let width = max(bounds.width, currentWidth)
            view.frame = NSRect(
                x: 0,
                y: converted.minY,
                width: width,
                height: converted.height
            ).integral
            view.isHidden = false
        }
    }

    // MARK: - Tool call popover

    private func showToolCallPopover(groupID: Int, anchorRect: NSRect) {
        guard let document = currentDocument,
              let group = document.toolCallGroups.first(where: { $0.id == groupID }) else { return }

        toolCallPopover?.performClose(nil)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let viewController = NSViewController()
        viewController.view = ToolCallGroupPopoverView(items: group.items)
        popover.contentViewController = viewController
        toolCallPopover = popover

        let converted = textView.convert(anchorRect, to: self)
        popover.show(relativeTo: converted, of: self, preferredEdge: .maxY)
    }

    private var colorSchemeThemeName: String {
        switch effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua: return "atom-one-dark"
        default: return "atom-one-light"
        }
    }
}
