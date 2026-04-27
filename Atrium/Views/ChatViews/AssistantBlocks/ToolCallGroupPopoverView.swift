import AppKit

final class ToolCallGroupPopoverView: NSView {
    private static let popoverWidth: CGFloat = 480
    private static let padding: CGFloat = 10
    private static let rowSpacing: CGFloat = 2
    private static let maxHeight: CGFloat = 360

    init(items: [ToolCallItem]) {
        super.init(frame: .zero)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        for item in items {
            let row = makeRow(for: item)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = documentView

        addSubview(scrollView)

        let heightMatchesContent = scrollView.heightAnchor.constraint(equalTo: documentView.heightAnchor)
        heightMatchesContent.priority = .defaultHigh

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maxHeight),
            heightMatchesContent,

            widthAnchor.constraint(equalToConstant: Self.popoverWidth),
        ])
    }

    private func makeRow(for item: ToolCallItem) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        let toolIcon = NSImageView(image: NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil) ?? NSImage())
        toolIcon.contentTintColor = .secondaryLabelColor
        toolIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        toolIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolIcon.widthAnchor.constraint(equalToConstant: 14),
            toolIcon.heightAnchor.constraint(equalToConstant: 14),
        ])

        let label = NSTextField(labelWithString: item.title)
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusSymbolName: String?
        let statusTint: NSColor
        switch item.status {
        case .pending:
            statusSymbolName = "clock"
            statusTint = .secondaryLabelColor
        case .inProgress:
            statusSymbolName = "ellipsis"
            statusTint = .secondaryLabelColor
        case .completed:
            statusSymbolName = "checkmark"
            statusTint = .systemGreen
        case .failed:
            statusSymbolName = "xmark"
            statusTint = .systemRed
        }

        row.addView(toolIcon, in: .leading)
        row.addView(label, in: .leading)

        if let name = statusSymbolName,
           let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let statusView = NSImageView(image: image)
            statusView.contentTintColor = statusTint
            statusView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            statusView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                statusView.widthAnchor.constraint(equalToConstant: 14),
                statusView.heightAnchor.constraint(equalToConstant: 14),
            ])
            statusView.setContentHuggingPriority(.required, for: .horizontal)
            row.addView(statusView, in: .trailing)
        }

        return row
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
