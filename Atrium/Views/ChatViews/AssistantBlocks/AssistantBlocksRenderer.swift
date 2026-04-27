import ACP
import AppKit
import Foundation

// MARK: - Document types

struct AssistantBlocksDocument: @unchecked Sendable {
    let attributedString: NSAttributedString
    let codeBlocks: [MarkdownCodeBlock]
    let quoteBlocks: [MarkdownQuoteBlock]
    let tableBlocks: [MarkdownTableBlock]
    let hasThematicBreaks: Bool
    let toolCallGroups: [ToolCallGroupSpec]
    let diffOverlays: [DiffOverlaySpec]
}

struct ToolCallGroupSpec: Sendable {
    let id: Int
    let range: NSRange
    let items: [ToolCallItem]
}

struct ToolCallItem: Sendable {
    let title: String
    let symbolName: String
    let status: ToolCallItemStatus
}

enum ToolCallItemStatus: Sendable {
    case pending
    case inProgress
    case completed
    case failed
}

struct DiffOverlaySpec: Sendable {
    let id: Int
    let range: NSRange
    let path: String
    let oldText: String?
    let newText: String
    let status: ToolCallItemStatus
    let reservedHeight: CGFloat
    let maxLines: Int?
}

// MARK: - Overlay attribute keys

extension NSAttributedString.Key {
    static let assistantToolCallGroupID = Self("AtriumAssistantToolCallGroupID")
    static let assistantDiffOverlayID = Self("AtriumAssistantDiffOverlayID")
}

// MARK: - Renderer

struct AssistantBlocksRenderer: Sendable {
    let fontSize: CGFloat
    let themeName: String

    nonisolated init(fontSize: CGFloat, themeName: String) {
        self.fontSize = fontSize
        self.themeName = themeName
    }

    nonisolated func render(blocks: [MessageBlock]) async -> AssistantBlocksDocument {
        let output = NSMutableAttributedString()

        var codeBlocks: [MarkdownCodeBlock] = []
        var quoteBlocks: [MarkdownQuoteBlock] = []
        var tableBlocks: [MarkdownTableBlock] = []
        var hasThematicBreaks = false

        var toolCallGroups: [ToolCallGroupSpec] = []
        var diffOverlays: [DiffOverlaySpec] = []

        var nextToolGroupID = 0
        var nextDiffID = 0

        let groups = Self.groupBlocks(blocks)
        let markdownRenderer = MacMarkdownRenderer(fontSize: fontSize, themeName: themeName)

        for group in groups {
            switch group.kind {
            case .text:
                guard let block = group.blocks.first, !block.text.isEmpty else { continue }

                if output.length > 0 {
                    output.append(Self.paragraphBreak())
                }

                let offset = output.length
                let doc = await markdownRenderer.render(block.text)
                output.append(doc.attributedString)

                codeBlocks.append(contentsOf: doc.codeBlocks.map {
                    MarkdownCodeBlock(
                        id: $0.id + codeBlocks.count,
                        range: NSRange(location: $0.range.location + offset, length: $0.range.length),
                        content: $0.content
                    )
                })
                quoteBlocks.append(contentsOf: doc.quoteBlocks.map {
                    MarkdownQuoteBlock(
                        range: NSRange(location: $0.range.location + offset, length: $0.range.length),
                        depth: $0.depth,
                        identity: $0.identity
                    )
                })
                tableBlocks.append(contentsOf: doc.tableBlocks.map {
                    MarkdownTableBlock(
                        id: $0.id + tableBlocks.count,
                        range: NSRange(location: $0.range.location + offset, length: $0.range.length),
                        content: $0.content,
                        headerCharacterCount: $0.headerCharacterCount
                    )
                })
                if doc.hasThematicBreaks { hasThematicBreaks = true }

            case .toolCalls:
                if output.length > 0 {
                    output.append(Self.paragraphBreak())
                }

                let groupID = nextToolGroupID
                nextToolGroupID += 1

                let items = group.blocks.map {
                    ToolCallItem(
                        title: $0.toolTitle ?? "Tool",
                        symbolName: $0.toolSymbolName,
                        status: Self.mapStatus($0.toolStatus)
                    )
                }

                let chip = Self.toolCallChipAttributedString(items: items, fontSize: fontSize, groupID: groupID)
                let start = output.length
                output.append(chip)
                let range = NSRange(location: start, length: output.length - start)

                toolCallGroups.append(ToolCallGroupSpec(id: groupID, range: range, items: items))

            case .editDiff:
                guard let block = group.blocks.first else { continue }

                if output.length > 0 {
                    output.append(Self.paragraphBreak())
                }

                let diffID = nextDiffID
                nextDiffID += 1

                let isWrite = block.isWriteWithContent
                let maxLines: Int? = isWrite ? 20 : nil

                let headerHeight: CGFloat = 24
                let diffFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                let lineHeight = ceil(diffFont.ascender - diffFont.descender + diffFont.leading)
                let unifiedLines = UnifiedDiff.lines(oldText: block.diffOldText, newText: block.diffNewText ?? "")
                let renderedLineCount: Int = {
                    if let cap = maxLines { return min(cap, max(1, unifiedLines.count)) }
                    return max(1, unifiedLines.count)
                }()
                let diffHeight = headerHeight + 3 + CGFloat(renderedLineCount) * lineHeight

                let placeholder = Self.diffPlaceholderAttributedString(height: diffHeight, diffID: diffID)
                let start = output.length
                output.append(placeholder)
                let range = NSRange(location: start, length: output.length - start)

                diffOverlays.append(DiffOverlaySpec(
                    id: diffID,
                    range: range,
                    path: block.diffPath ?? "",
                    oldText: block.diffOldText,
                    newText: block.diffNewText ?? "",
                    status: Self.mapStatus(block.toolStatus),
                    reservedHeight: diffHeight,
                    maxLines: maxLines
                ))

            }
        }

        return AssistantBlocksDocument(
            attributedString: output,
            codeBlocks: codeBlocks,
            quoteBlocks: quoteBlocks,
            tableBlocks: tableBlocks,
            hasThematicBreaks: hasThematicBreaks,
            toolCallGroups: toolCallGroups,
            diffOverlays: diffOverlays
        )
    }

    // MARK: - Grouping

    private struct Group {
        enum Kind { case text, toolCalls, editDiff }
        let kind: Kind
        var blocks: [MessageBlock]
    }

    private static func groupBlocks(_ blocks: [MessageBlock]) -> [Group] {
        var groups: [Group] = []
        for block in blocks {
            // Blocks that render nothing shouldn't split runs of tool calls.
            if block.isThought { continue }
            if block.isText && block.text.isEmpty { continue }

            if block.isEditWithDiff || block.isWriteWithContent {
                groups.append(Group(kind: .editDiff, blocks: [block]))
            } else if block.isToolCall {
                if let last = groups.last, last.kind == .toolCalls {
                    groups[groups.count - 1].blocks.append(block)
                } else {
                    groups.append(Group(kind: .toolCalls, blocks: [block]))
                }
            } else {
                groups.append(Group(kind: .text, blocks: [block]))
            }
        }
        return groups
    }

    private static func mapStatus(_ status: ACP.ToolStatus?) -> ToolCallItemStatus {
        switch status {
        case .pending: return .pending
        case .inProgress: return .inProgress
        case .completed: return .completed
        case .failed: return .failed
        case .none: return .pending
        }
    }

    // MARK: - Chip attributed string

    static func toolCallChipAttributedString(
        items: [ToolCallItem],
        fontSize: CGFloat,
        groupID: Int
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: max(fontSize - 1, 11), weight: .regular)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.lineSpacing = 2
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
            .assistantToolCallGroupID: groupID
        ]

        // Unique icons (leading)
        var seenIcons: Set<String> = []
        for item in items where seenIcons.insert(item.symbolName).inserted {
            if let icon = symbolAttachment(name: item.symbolName, fontSize: font.pointSize) {
                let iconStr = NSMutableAttributedString(attachment: icon)
                iconStr.addAttributes(baseAttrs, range: NSRange(location: 0, length: iconStr.length))
                result.append(iconStr)
                result.append(NSAttributedString(string: " ", attributes: baseAttrs))
            }
        }

        // Label
        let label: String
        if items.count == 1 {
            label = items[0].title
        } else {
            label = "\(items.count) tool calls"
        }
        result.append(NSAttributedString(string: label, attributes: baseAttrs))

        // Overall status — only render on failure or in-progress; success is implicit.
        if let statusAttachment = overallStatusAttachment(for: items, fontSize: font.pointSize) {
            result.append(NSAttributedString(string: "  ", attributes: baseAttrs))
            let suffix = NSMutableAttributedString(attachment: statusAttachment.image)
            suffix.addAttributes(baseAttrs, range: NSRange(location: 0, length: suffix.length))
            suffix.addAttribute(.foregroundColor, value: statusAttachment.color, range: NSRange(location: 0, length: suffix.length))
            result.append(suffix)
        }

        return result
    }

    private static func overallStatusAttachment(for items: [ToolCallItem], fontSize: CGFloat) -> (image: NSTextAttachment, color: NSColor)? {
        let hasFailed = items.contains(where: { $0.status == .failed })
        let hasInProgress = items.contains(where: { $0.status == .inProgress })
        let name: String
        let color: NSColor
        if hasFailed {
            name = "xmark"
            color = .systemRed
        } else if hasInProgress {
            name = "ellipsis"
            color = .secondaryLabelColor
        } else {
            return nil
        }
        guard let att = symbolAttachment(name: name, fontSize: fontSize, tint: color) else { return nil }
        return (att, color)
    }

    private static func symbolAttachment(name: String, fontSize: CGFloat, tint: NSColor? = nil) -> NSTextAttachment? {
        let config = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            ?? NSImage(named: name)
        else {
            return nil
        }
        let attachment = NSTextAttachment()
        if let tint {
            attachment.image = symbol.tinted(with: tint)
        } else {
            attachment.image = symbol
        }
        let imageSize = attachment.image?.size ?? .zero
        attachment.bounds = CGRect(x: 0, y: -2, width: imageSize.width, height: imageSize.height)
        return attachment
    }

    // MARK: - Diff placeholder

    static func diffPlaceholderAttributedString(height: CGFloat, diffID: Int) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = height
        paragraphStyle.maximumLineHeight = height
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.lineSpacing = 0

        let str = NSMutableAttributedString(string: "\u{200B}", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
            .foregroundColor: NSColor.clear,
            .paragraphStyle: paragraphStyle,
            .assistantDiffOverlayID: diffID
        ])
        return str
    }

    // MARK: - Paragraph break between blocks

    static func paragraphBreak() -> NSAttributedString {
        NSAttributedString(string: "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 6),
            .foregroundColor: NSColor.clear
        ])
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        self.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        rect.fill(using: .sourceIn)
        return image
    }
}
