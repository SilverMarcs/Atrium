import AppKit

private final class HeaderButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        return bounds.contains(localPoint) ? self : nil
    }
}

final class DiffOverlayView: NSView {
    private let headerContainer = HeaderButton()
    private let pathIcon = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    // private let openButton = NSButton()

    private let borderView = NSView()

    private let diffScrollView = HorizontalOnlyScrollView()
    private let diffTextView = SharedDiffTextView()

    private var currentSpec: DiffOverlaySpec?

    var onOpenFile: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        // layer?.borderWidth = 1

        setupHeader()
        setupDiffArea()
        applyAppearanceColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func menu(for event: NSEvent) -> NSMenu? {
        markdownAncestorMenu(from: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.clear.cgColor
            // layer?.backgroundColor = NSColor.quinarySystemFill.cgColor
            // layer?.borderColor = NSColor.separatorColor.cgColor
            borderView.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    private func setupHeader() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        pathIcon.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        // openButton.translatesAutoresizingMaskIntoConstraints = false
        borderView.translatesAutoresizingMaskIntoConstraints = false

        pathIcon.image = NSImage(systemSymbolName: "pencil.line", accessibilityDescription: nil)
        pathIcon.contentTintColor = .secondaryLabelColor
        pathIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)

        pathLabel.font = .systemFont(ofSize: 12, weight: .medium)
        pathLabel.textColor = .labelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.cell?.wraps = false

        headerContainer.title = ""
        headerContainer.isBordered = false
        headerContainer.bezelStyle = .regularSquare
        headerContainer.setButtonType(.momentaryChange)
        headerContainer.focusRingType = .none
        headerContainer.toolTip = "Open file"
        headerContainer.target = self
        headerContainer.action = #selector(pathLabelClicked(_:))

        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor

        // openButton.bezelStyle = .accessoryBarAction
        // openButton.isBordered = false
        // openButton.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Open file")
        // openButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        // openButton.contentTintColor = .secondaryLabelColor
        // openButton.toolTip = "Open file"
        // openButton.target = self
        // openButton.action = #selector(pathLabelClicked(_:))
        // openButton.setButtonType(.momentaryChange)

        borderView.wantsLayer = true

        headerContainer.addSubview(pathIcon)
        headerContainer.addSubview(pathLabel)
        headerContainer.addSubview(statsLabel)
        // headerContainer.addSubview(openButton)

        addSubview(headerContainer)
        addSubview(borderView)

        NSLayoutConstraint.activate([
            headerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerContainer.topAnchor.constraint(equalTo: topAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 24),

            pathIcon.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            pathIcon.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            pathLabel.leadingAnchor.constraint(equalTo: pathIcon.trailingAnchor, constant: 6),
            pathLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            statsLabel.leadingAnchor.constraint(equalTo: pathLabel.trailingAnchor, constant: 8),
            statsLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            // openButton.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -8),
            // openButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            // openButton.widthAnchor.constraint(equalToConstant: 18),
            // openButton.heightAnchor.constraint(equalToConstant: 18),

            borderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            borderView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            borderView.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    @objc private func pathLabelClicked(_ sender: Any?) {
        guard let spec = currentSpec else { return }
        onOpenFile?(spec.path)
    }

    private func setupDiffArea() {
        diffScrollView.translatesAutoresizingMaskIntoConstraints = false
        diffScrollView.hasVerticalScroller = false
        diffScrollView.hasHorizontalScroller = true
        diffScrollView.autohidesScrollers = true
        diffScrollView.verticalScrollElasticity = .none
        diffScrollView.drawsBackground = false
        diffScrollView.borderType = .noBorder

        diffScrollView.documentView = diffTextView
        addSubview(diffScrollView)

        NSLayoutConstraint.activate([
            diffScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            diffScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffScrollView.topAnchor.constraint(equalTo: borderView.bottomAnchor, constant: 2),
            diffScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configure(spec: DiffOverlaySpec) {
        currentSpec = spec

        pathLabel.stringValue = (spec.path as NSString).lastPathComponent

        let allLines = UnifiedDiff.lines(oldText: spec.oldText, newText: spec.newText)
        let rawLines: [SharedDiffLine] = {
            if let cap = spec.maxLines, allLines.count > cap {
                return Array(allLines.prefix(cap))
            }
            return allLines
        }()
        let lines = Self.trimCommonLeadingWhitespace(rawLines)

        let added = allLines.filter { $0.kind == .added }.count
        let removed = allLines.filter { $0.kind == .removed }.count
        let statsText = NSMutableAttributedString()
        if added > 0 {
            statsText.append(NSAttributedString(
                string: "+\(added)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.systemGreen
                ]
            ))
        }
        if added > 0 && removed > 0 {
            statsText.append(NSAttributedString(string: " "))
        }
        if removed > 0 {
            statsText.append(NSAttributedString(
                string: "-\(removed)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.systemRed
                ]
            ))
        }
        statsLabel.attributedStringValue = statsText

        let ext = (spec.path as NSString).pathExtension
        diffTextView.configure(
            lines: lines,
            fileExtension: ext,
            layout: Self.inlineLayout(for: lines),
            width: bounds.width
        )
    }

    private static func inlineLayout(for lines: [SharedDiffLine]) -> SharedDiffTextLayout {
        let lineNumberFontSize: CGFloat = 11
        let maxLineNumber = lines.reduce(0) { partial, line in
            Swift.max(partial, line.newLineNumber ?? 0, line.oldLineNumber ?? 0)
        }
        let digits = maxLineNumber > 0 ? String(maxLineNumber) : "0"
        let font = NSFont.monospacedDigitSystemFont(ofSize: lineNumberFontSize, weight: .regular)
        let digitsWidth = (digits as NSString).size(withAttributes: [.font: font]).width
        let gutterWidth = ceil(digitsWidth) + 10

        return SharedDiffTextLayout(
            gutterWidth: gutterWidth,
            verticalPadding: 0,
            wrapsLines: false,
            fontSize: 12,
            lineNumberFontSize: lineNumberFontSize
        )
    }

    func refreshAppearance() {
        guard let spec = currentSpec else { return }
        configure(spec: spec)
    }

    private static func trimCommonLeadingWhitespace(_ lines: [SharedDiffLine]) -> [SharedDiffLine] {
        var minLeading = Int.max
        for line in lines {
            let content = line.content
            if content.isEmpty { continue }
            var count = 0
            var sawNonWhitespace = false
            for char in content {
                if char == " " || char == "\t" {
                    count += 1
                } else {
                    sawNonWhitespace = true
                    break
                }
            }
            guard sawNonWhitespace else { continue }
            if count < minLeading { minLeading = count }
            if minLeading == 0 { return lines }
        }
        guard minLeading != Int.max, minLeading > 0 else { return lines }

        return lines.map { line in
            let content = line.content
            var leading = 0
            for char in content {
                if char == " " || char == "\t" {
                    leading += 1
                } else {
                    break
                }
            }
            let dropCount = Swift.min(minLeading, leading)
            let trimmed = String(content.dropFirst(dropCount))
            return SharedDiffLine(
                content: trimmed,
                kind: line.kind,
                oldLineNumber: line.oldLineNumber,
                newLineNumber: line.newLineNumber
            )
        }
    }
}
