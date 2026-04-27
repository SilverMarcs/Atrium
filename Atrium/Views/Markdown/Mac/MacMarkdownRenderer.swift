import AppKit
import Foundation

struct MarkdownRenderedDocument: @unchecked Sendable {
    // This is an immutable render snapshot that is produced off the main actor
    // and then handed to the main actor for display without subsequent mutation.
    let attributedString: NSAttributedString
    let codeBlocks: [MarkdownCodeBlock]
    let quoteBlocks: [MarkdownQuoteBlock]
    let tableBlocks: [MarkdownTableBlock]
    let hasThematicBreaks: Bool
}

struct MarkdownCodeBlock: Sendable {
    let id: Int
    let range: NSRange
    let content: String
}

struct MarkdownQuoteBlock: Sendable {
    let range: NSRange
    let depth: Int
    let identity: Int
}

struct MarkdownTableBlock: Sendable {
    let id: Int
    let range: NSRange
    let content: String
    let headerCharacterCount: Int

    static func parseCells(from line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content = String(content.dropFirst()) }
        if content.hasSuffix("|") { content = String(content.dropLast()) }
        return content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isSeparatorLine(_ line: String) -> Bool {
        let cells = parseCells(from: line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return !stripped.isEmpty && stripped.allSatisfy({ $0 == "-" })
        }
    }
}

extension MarkdownRenderedDocument {
    static func placeholder(text: String, fontSize: CGFloat) -> MarkdownRenderedDocument {
        return MarkdownRenderedDocument(
            attributedString: plainTextFragment(text, fontSize: fontSize),
            codeBlocks: [],
            quoteBlocks: [],
            tableBlocks: [],
            hasThematicBreaks: false
        )
    }

    private static let plainTextParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style.copy() as! NSParagraphStyle
    }()

    static func plainTextFragment(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: max(fontSize, 13), weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: plainTextParagraphStyle
            ]
        )
    }
}

struct MacMarkdownRenderer: Sendable {
    private enum Segment {
        case markdown(String)
        case codeBlock(String, language: String?)
        case table(headers: [String], rows: [[String]], rawContent: String)
    }

    private struct RenderedTextUnit {
        let attributedString: NSAttributedString
        let context: BlockContext
    }

    private struct BlockContext: Equatable {
        enum Kind: Equatable {
            case paragraph
            case heading(Int)
            case listItem(ListContext)
            case thematicBreak
        }

        struct ListContext: Equatable {
            enum Marker: Equatable {
                case bullet
                case ordered(Int)
            }

            let marker: Marker
            let level: Int
            let groupIdentity: Int
        }

        let kind: Kind
        let quoteDepth: Int
        let quoteIdentity: Int?
        let blockIdentity: Int
    }

    private enum ListMarker {
        case bullet
        case ordered(Int)
    }

    private struct MarkdownListContext {
        let marker: ListMarker
        let level: Int
        let groupIdentity: Int
    }

    private struct MarkdownPresentationContext {
        enum Kind {
            case paragraph
            case heading(Int)
            case thematicBreak
        }

        let kind: Kind
        let quoteDepth: Int
        let quoteIdentity: Int?
        let blockIdentity: Int
        let listContext: MarkdownListContext?
    }

    private let bodyFontSize: CGFloat
    private let codeFontSize: CGFloat
    private let themeName: String
    private nonisolated(unsafe) let cachedDefaultParagraphStyle: NSParagraphStyle
    private nonisolated(unsafe) let cachedCodeBlockParagraphStyle: NSParagraphStyle
    private nonisolated(unsafe) let cachedCodeBlockSpacerStyle: NSParagraphStyle
    private nonisolated(unsafe) let cachedTableSpacerStyle: NSParagraphStyle
    private nonisolated(unsafe) let cachedBulletMarkerWidth: CGFloat

    nonisolated init(fontSize: CGFloat, themeName: String) {
        bodyFontSize = max(fontSize, 13)
        codeFontSize = max(bodyFontSize - 1, 12)
        self.themeName = themeName

        let defaultStyle = NSMutableParagraphStyle()
        defaultStyle.lineSpacing = 4
        defaultStyle.paragraphSpacing = 0
        cachedDefaultParagraphStyle = defaultStyle.copy() as! NSParagraphStyle

        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 3
        codeStyle.firstLineHeadIndent = 10
        codeStyle.headIndent = 10
        codeStyle.tailIndent = -10
        codeStyle.lineBreakMode = .byCharWrapping
        cachedCodeBlockParagraphStyle = codeStyle.copy() as! NSParagraphStyle

        cachedCodeBlockSpacerStyle = Self.makeSpacerStyle(height: 8)
        cachedTableSpacerStyle = Self.makeSpacerStyle(height: 1)

        let bodyFont = NSFont.systemFont(ofSize: bodyFontSize, weight: .regular)
        cachedBulletMarkerWidth = "•".size(withAttributes: [.font: bodyFont]).width
    }

    private static func makeSpacerStyle(height: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return style.copy() as! NSParagraphStyle
    }

    nonisolated func render(_ markdown: String) async -> MarkdownRenderedDocument {
        let output = NSMutableAttributedString()
        var codeBlocks: [MarkdownCodeBlock] = []
        var quoteBlocks: [MarkdownQuoteBlock] = []
        var tableBlocks: [MarkdownTableBlock] = []
        var hasThematicBreaks = false
        var nextCodeBlockID = 0
        var nextTableBlockID = 0

        for segment in parseSegments(markdown) {
            let attributedSegment: NSAttributedString?
            var currentTableResult: RenderedTableResult?
            var segmentQuoteBlocks: [MarkdownQuoteBlock]?

            switch segment {
            case .markdown(let markdown):
                if let result = renderedMarkdownSegment(from: markdown) {
                    attributedSegment = result.attributedString
                    segmentQuoteBlocks = result.quoteBlocks
                    if result.hasThematicBreaks { hasThematicBreaks = true }
                } else {
                    attributedSegment = nil
                }
            case .codeBlock(let code, let language):
                attributedSegment = await renderedCodeBlock(
                    content: code,
                    language: language,
                    blockID: nextCodeBlockID
                )
                nextCodeBlockID += 1
            case .table(let headers, let rows, _):
                let tableResult = renderedTableResult(
                    headers: headers,
                    rows: rows,
                    blockID: nextTableBlockID
                )
                currentTableResult = tableResult
                attributedSegment = tableResult.attributedString
                nextTableBlockID += 1
            }

            guard let attributedSegment, attributedSegment.length > 0 else { continue }

            if output.length > 0 {
                output.append(NSAttributedString(string: "\n\n"))
            }

            let range = NSRange(location: output.length, length: attributedSegment.length)
            output.append(attributedSegment)

            if case .codeBlock(let content, _) = segment {
                codeBlocks.append(
                    MarkdownCodeBlock(
                        id: nextCodeBlockID - 1,
                        range: range,
                        content: content
                    )
                )
            }

            if case .table(_, _, let rawContent) = segment, let tableResult = currentTableResult {
                tableBlocks.append(
                    MarkdownTableBlock(
                        id: nextTableBlockID - 1,
                        range: range,
                        content: rawContent,
                        headerCharacterCount: tableResult.headerCharacterCount
                    )
                )
            }

            if let segmentQuoteBlocks {
                let offsetBlocks = segmentQuoteBlocks.map { block in
                    MarkdownQuoteBlock(
                        range: NSRange(location: block.range.location + range.location, length: block.range.length),
                        depth: block.depth,
                        identity: block.identity
                    )
                }
                mergeQuoteBlocks(&quoteBlocks, with: offsetBlocks)
            }

            switch segment {
            case .codeBlock:
                appendBlockOverhangSpacer(to: output, style: cachedCodeBlockSpacerStyle)
            case .table:
                appendBlockOverhangSpacer(to: output, style: cachedTableSpacerStyle)
            default:
                break
            }
        }

        return MarkdownRenderedDocument(
            attributedString: output,
            codeBlocks: codeBlocks,
            quoteBlocks: quoteBlocks,
            tableBlocks: tableBlocks,
            hasThematicBreaks: hasThematicBreaks
        )
    }

    private nonisolated func appendBlockOverhangSpacer(to output: NSMutableAttributedString, style: NSParagraphStyle) {
        output.append(NSAttributedString(
            string: "\n\u{200B}",
            attributes: [
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear,
                .paragraphStyle: style
            ]
        ))
    }

    private struct RenderedMarkdownResult {
        let attributedString: NSAttributedString
        let quoteBlocks: [MarkdownQuoteBlock]
        let hasThematicBreaks: Bool
    }

    private nonisolated func renderedMarkdownSegment(from markdown: String) -> RenderedMarkdownResult? {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let result = styledMarkdown(markdown)
        guard result.attributedString.length > 0 else { return nil }
        return result
    }

    private nonisolated func renderedCodeBlock(
        content: String,
        language: String?,
        blockID: Int
    ) async -> NSAttributedString {
        let codeFont = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
        let output = NSMutableAttributedString(
            string: content,
            attributes: [.foregroundColor: NSColor.labelColor]
        )

        output.addAttributes([
            .font: codeFont,
            .paragraphStyle: codeBlockParagraphStyle(),
            .markdownCodeBlockID: blockID
        ], range: output.fullRange)

        return output
    }

    private nonisolated func parseSegments(_ markdown: String) -> [Segment] {
        let lines = markdown.components(separatedBy: .newlines)
        var segments: [Segment] = []
        var markdownLines: [String] = []
        var index = 0

        func flushMarkdownLines() {
            let chunk = markdownLines.joined(separator: "\n")
            guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                markdownLines.removeAll(keepingCapacity: true)
                return
            }

            segments.append(.markdown(chunk))
            markdownLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushMarkdownLines()

                let language = parseCodeBlockLanguage(from: trimmed)
                var codeLines: [String] = []
                index += 1

                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "```" {
                    codeLines.append(lines[index])
                    index += 1
                }

                if index < lines.count {
                    index += 1
                }

                segments.append(.codeBlock(codeLines.joined(separator: "\n"), language: language))
                continue
            }

            if isTableRow(trimmed),
               index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                flushMarkdownLines()

                let headers = parseTableCells(trimmed)
                let separatorLine = lines[index + 1]
                var tableLines = [line, separatorLine]
                index += 2

                var rows: [[String]] = []
                while index < lines.count, isTableRow(lines[index]) {
                    rows.append(parseTableCells(lines[index]))
                    tableLines.append(lines[index])
                    index += 1
                }

                segments.append(.table(
                    headers: headers,
                    rows: rows,
                    rawContent: tableLines.joined(separator: "\n")
                ))
                continue
            }

            markdownLines.append(line)
            index += 1
        }

        flushMarkdownLines()
        return segments
    }

    private nonisolated func parseCodeBlockLanguage(from trimmedFenceLine: String) -> String? {
        let languageHint = trimmedFenceLine
            .dropFirst(3)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !languageHint.isEmpty else {
            return nil
        }

        return languageHint
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
    }

    private nonisolated func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.hasPrefix("```")
    }

    private nonisolated func isTableSeparator(_ line: String) -> Bool {
        MarkdownTableBlock.isSeparatorLine(line)
    }

    private nonisolated func parseTableCells(_ line: String) -> [String] {
        MarkdownTableBlock.parseCells(from: line)
    }

    private struct RenderedTableResult {
        let attributedString: NSAttributedString
        let headerCharacterCount: Int
    }

    private nonisolated func renderedTableResult(
        headers: [String],
        rows: [[String]],
        blockID: Int
    ) -> RenderedTableResult {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else {
            return RenderedTableResult(
                attributedString: NSAttributedString(),
                headerCharacterCount: 0
            )
        }

        let paddedHeaders = headers + Array(repeating: "", count: max(0, columnCount - headers.count))
        let paddedRows = rows.map { row in
            row + Array(repeating: "", count: max(0, columnCount - row.count))
        }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.setContentWidth(100, type: .percentageValueType)
        table.hidesEmptyCells = false
        table.collapsesBorders = true

        let headerFont = NSFont.systemFont(ofSize: bodyFontSize, weight: .semibold)
        let cellFont = bodyFont()

        // Measure max text width per column for proportional sizing
        let cellPadding: CGFloat = 16 // 8 + 8
        var columnWidths = [CGFloat](repeating: 0, count: columnCount)
        for (col, header) in paddedHeaders.enumerated() {
            let width = header.size(withAttributes: [.font: headerFont]).width + cellPadding
            columnWidths[col] = max(columnWidths[col], width)
        }
        for row in paddedRows {
            for (col, cell) in row.enumerated() {
                let width = cell.size(withAttributes: [.font: cellFont]).width + cellPadding
                columnWidths[col] = max(columnWidths[col], width)
            }
        }
        let totalWidth = columnWidths.reduce(0, +)
        let columnPercentages: [CGFloat] = totalWidth > 0
            ? columnWidths.map { ($0 / totalWidth) * 100 }
            : [CGFloat](repeating: 100 / CGFloat(columnCount), count: columnCount)

        let alternateRowColor = NSColor.quaternarySystemFill
        let output = NSMutableAttributedString()

        func makeCellString(row: Int, col: Int, text: String, font: NSFont, isHeader: Bool) -> NSAttributedString {
            let block = NSTextTableBlock(
                table: table,
                startingRow: row,
                rowSpan: 1,
                startingColumn: col,
                columnSpan: 1
            )

            block.setContentWidth(columnPercentages[col], type: .percentageValueType)

            block.setWidth(5, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(5, type: .absoluteValueType, for: .padding, edge: .maxY)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)

            block.setWidth(0.5, type: .absoluteValueType, for: .border)
            block.setBorderColor(.separatorColor)

            if isHeader {
                block.backgroundColor = .quaternarySystemFill
            } else {
                // row is 1-based for data rows; even data rows (row 2, 4, ...) get alternate bg
                block.backgroundColor = row % 2 == 0 ? alternateRowColor : .clear
            }

            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            style.lineSpacing = 2
            style.lineBreakMode = .byWordWrapping

            // Parse inline markdown (bold, italic, inline code)
            let cellContent: NSMutableAttributedString
            if let parsed = try? NSAttributedString(
                markdown: text,
                options: .init(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                ),
                baseURL: nil
            ) {
                cellContent = NSMutableAttributedString(attributedString: parsed)
                normalizeFonts(in: cellContent)
                applyInlineCodeStyling(to: cellContent)
            } else {
                cellContent = NSMutableAttributedString(string: text)
            }

            // Apply cell-level attributes
            let fullRange = NSRange(location: 0, length: cellContent.length)
            cellContent.addAttributes([
                .paragraphStyle: style,
                .markdownTableBlockID: blockID
            ], range: fullRange)

            // Set base font for non-styled runs, preserve bold from normalization
            cellContent.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                guard let existingFont = value as? NSFont else {
                    cellContent.addAttribute(.font, value: font, range: range)
                    return
                }
                let traits = existingFont.fontDescriptor.symbolicTraits
                if isHeader || traits.contains(.bold) {
                    let weight: NSFont.Weight = .semibold
                    if traits.contains(.monoSpace) {
                        cellContent.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: weight), range: range)
                    } else {
                        cellContent.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize, weight: weight), range: range)
                    }
                } else if !traits.contains(.monoSpace) {
                    cellContent.addAttribute(.font, value: font, range: range)
                }
            }

            // Set foreground color only where not already set by inline code styling
            cellContent.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
                if value == nil {
                    cellContent.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                }
            }

            cellContent.append(NSAttributedString(
                string: "\n",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: style,
                    .markdownTableBlockID: blockID
                ]
            ))

            return cellContent
        }

        var headerCharCount = 0
        for (col, header) in paddedHeaders.enumerated() {
            output.append(makeCellString(row: 0, col: col, text: header, font: headerFont, isHeader: true))
            headerCharCount += header.count + 1
        }

        for (rowIdx, row) in paddedRows.enumerated() {
            for (col, cell) in row.enumerated() {
                output.append(makeCellString(row: rowIdx + 1, col: col, text: cell, font: cellFont, isHeader: false))
            }
        }

        return RenderedTableResult(
            attributedString: output,
            headerCharacterCount: headerCharCount
        )
    }

    private nonisolated func styledMarkdown(_ markdown: String) -> RenderedMarkdownResult {
        let parsed: NSMutableAttributedString

        if let attributed = try? NSAttributedString(
            markdown: markdown,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            ),
            baseURL: nil
        ) {
            parsed = NSMutableAttributedString(attributedString: attributed)
        } else {
            parsed = NSMutableAttributedString(string: markdown)
        }

        let units = renderedTextUnits(from: parsed)
        let output = NSMutableAttributedString()
        var quoteBlocks: [MarkdownQuoteBlock] = []
        var hasThematicBreaks = false
        var index = 0

        while index < units.count {
            let unit = units[index]

            switch unit.context.kind {
            case .listItem(let listContext):
                if output.length > 0 {
                    output.append(NSAttributedString(string: "\n\n"))
                }

                let blockStart = output.length
                var isFirstItem = true
                while index < units.count {
                    guard case .listItem(let candidateContext) = units[index].context.kind,
                          candidateContext.groupIdentity == listContext.groupIdentity else {
                        break
                    }

                    if !isFirstItem {
                        output.append(NSAttributedString(string: "\n"))
                    }

                    output.append(styledListItem(units[index]))
                    isFirstItem = false
                    index += 1
                }

                if unit.context.quoteDepth > 0 {
                    let length = output.length - blockStart
                    if length > 0 {
                        quoteBlocks.append(MarkdownQuoteBlock(
                            range: NSRange(location: blockStart, length: length),
                            depth: unit.context.quoteDepth,
                            identity: unit.context.quoteIdentity ?? unit.context.blockIdentity
                        ))
                    }
                }

            default:
                if output.length > 0 {
                    output.append(NSAttributedString(string: "\n\n"))
                }

                if case .thematicBreak = unit.context.kind {
                    hasThematicBreaks = true
                }

                let blockStart = output.length
                output.append(styledBlock(unit))

                if unit.context.quoteDepth > 0 {
                    let length = output.length - blockStart
                    if length > 0 {
                        quoteBlocks.append(MarkdownQuoteBlock(
                            range: NSRange(location: blockStart, length: length),
                            depth: unit.context.quoteDepth,
                            identity: unit.context.quoteIdentity ?? unit.context.blockIdentity
                        ))
                    }
                }

                index += 1
            }
        }

        return RenderedMarkdownResult(attributedString: output, quoteBlocks: quoteBlocks, hasThematicBreaks: hasThematicBreaks)
    }

    private nonisolated func renderedTextUnits(from attributedString: NSAttributedString) -> [RenderedTextUnit] {
        let fullRange = attributedString.fullRange
        guard fullRange.length > 0 else { return [] }

        var units: [RenderedTextUnit] = []
        var currentContext: BlockContext?
        var currentString = NSMutableAttributedString()

        func flushCurrentUnit() {
            guard let currentContext, currentString.length > 0 else { return }
            units.append(
                RenderedTextUnit(
                    attributedString: NSAttributedString(attributedString: currentString),
                    context: currentContext
                )
            )
            currentString = NSMutableAttributedString()
        }

        unsafe attributedString.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let context = blockContext(for: attributes[.markdownPresentationIntent] as? PresentationIntent)
            let substring = NSMutableAttributedString(
                attributedString: attributedString.attributedSubstring(from: range)
            )
            substring.removeAttribute(.markdownPresentationIntent, range: substring.fullRange)
            substring.removeAttribute(.markdownListItemDelimiter, range: substring.fullRange)

            if currentContext == context {
                currentString.append(substring)
            } else {
                flushCurrentUnit()
                currentContext = context
                currentString = substring
            }
        }

        flushCurrentUnit()
        return units
    }

    private nonisolated func blockContext(for presentationIntent: PresentationIntent?) -> BlockContext {
        let context = presentationContext(for: presentationIntent)

        if let listContext = context.listContext {
            return BlockContext(
                kind: .listItem(
                    .init(
                        marker: listMarker(for: listContext.marker),
                        level: listContext.level,
                        groupIdentity: listContext.groupIdentity
                    )
                ),
                quoteDepth: context.quoteDepth,
                quoteIdentity: context.quoteIdentity,
                blockIdentity: context.blockIdentity
            )
        }

        let kind: BlockContext.Kind
        switch context.kind {
        case .paragraph:
            kind = .paragraph
        case .heading(let level):
            kind = .heading(level)
        case .thematicBreak:
            kind = .thematicBreak
        }

        return BlockContext(
            kind: kind,
            quoteDepth: context.quoteDepth,
            quoteIdentity: context.quoteIdentity,
            blockIdentity: context.blockIdentity
        )
    }

    private nonisolated func presentationContext(for presentationIntent: PresentationIntent?) -> MarkdownPresentationContext {
        let components = presentationIntent?.components ?? []
        let quoteIdentity = components.first { component in
            if case .blockQuote = component.kind {
                true
            } else {
                false
            }
        }?.identity
        let quoteDepth = components.reduce(into: 0) { count, component in
            if case .blockQuote = component.kind {
                count += 1
            }
        }

        if let thematicBreak = components.first(where: isThematicBreak) {
            return MarkdownPresentationContext(
                kind: .thematicBreak,
                quoteDepth: quoteDepth,
                quoteIdentity: quoteIdentity,
                blockIdentity: thematicBreak.identity,
                listContext: nil
            )
        }

        if let header = components.first(where: isHeader) {
            guard case let .header(level) = header.kind else {
                return MarkdownPresentationContext(
                    kind: .paragraph,
                    quoteDepth: quoteDepth,
                    quoteIdentity: quoteIdentity,
                    blockIdentity: header.identity,
                    listContext: nil
                )
            }

            return MarkdownPresentationContext(
                kind: .heading(level),
                quoteDepth: quoteDepth,
                quoteIdentity: quoteIdentity,
                blockIdentity: header.identity,
                listContext: nil
            )
        }

        let paragraph = components.first(where: isParagraph)
        let listItem = components.first(where: isListItem)
        let list = components.first(where: isList)

        let listContext: MarkdownListContext?
        if let listItem, let list {
            let marker: ListMarker
            switch (list.kind, listItem.kind) {
            case (.orderedList, .listItem(let ordinal)):
                marker = .ordered(ordinal)
            default:
                marker = .bullet
            }

            listContext = MarkdownListContext(
                marker: marker,
                level: max(presentationIntent?.indentationLevel ?? 1, 1),
                groupIdentity: list.identity
            )
        } else {
            listContext = nil
        }

        return MarkdownPresentationContext(
            kind: .paragraph,
            quoteDepth: quoteDepth,
            quoteIdentity: quoteIdentity,
            blockIdentity: paragraph?.identity ?? components.first?.identity ?? 0,
            listContext: listContext
        )
    }

    private nonisolated func isParagraph(_ component: PresentationIntent.IntentType) -> Bool {
        if case .paragraph = component.kind {
            true
        } else {
            false
        }
    }

    private nonisolated func isHeader(_ component: PresentationIntent.IntentType) -> Bool {
        if case .header = component.kind {
            true
        } else {
            false
        }
    }

    private nonisolated func isList(_ component: PresentationIntent.IntentType) -> Bool {
        switch component.kind {
        case .orderedList, .unorderedList:
            true
        default:
            false
        }
    }

    private nonisolated func isListItem(_ component: PresentationIntent.IntentType) -> Bool {
        if case .listItem = component.kind {
            true
        } else {
            false
        }
    }

    private nonisolated func isThematicBreak(_ component: PresentationIntent.IntentType) -> Bool {
        if case .thematicBreak = component.kind {
            true
        } else {
            false
        }
    }

    private nonisolated func styledBlock(_ unit: RenderedTextUnit) -> NSAttributedString {
        switch unit.context.kind {
        case .listItem:
            return styledListItem(unit)
        case .thematicBreak:
            return thematicBreakAttributedString(quoteDepth: unit.context.quoteDepth)
        case .paragraph, .heading:
            let output = NSMutableAttributedString(attributedString: unit.attributedString)
            normalizeFonts(in: output)

            let paragraphStyle = paragraphStyle(
                paragraphStyle(),
                adjustedForQuoteDepth: unit.context.quoteDepth
            )
            let foregroundColor = unit.context.quoteDepth > 0 ? quoteTextColor() : NSColor.labelColor

            output.addAttribute(.paragraphStyle, value: paragraphStyle, range: output.fullRange)
            output.addAttribute(.foregroundColor, value: foregroundColor, range: output.fullRange)

            if case .heading(let level) = unit.context.kind {
                output.addAttribute(.font, value: headingFont(for: level), range: output.fullRange)
            }

            applyInlineCodeStyling(to: output)
            return output
        }
    }

    private nonisolated func styledListItem(_ unit: RenderedTextUnit) -> NSAttributedString {
        guard case .listItem(let listContext) = unit.context.kind else {
            return styledBlock(unit)
        }

        let marker = markerText(for: listContext.marker)
        let markerIndent = CGFloat(max(0, listContext.level - 1)) * 20
        let style = paragraphStyle(
            listParagraphStyle(markerIndent: markerIndent, marker: marker),
            adjustedForQuoteDepth: unit.context.quoteDepth
        )
        let foregroundColor = unit.context.quoteDepth > 0 ? quoteTextColor() : NSColor.labelColor

        let output = NSMutableAttributedString(
            string: "\(marker)\t",
            attributes: [
                .font: bodyFont(),
                .paragraphStyle: style,
                .foregroundColor: foregroundColor
            ]
        )

        let content = NSMutableAttributedString(attributedString: unit.attributedString)
        normalizeFonts(in: content)
        content.addAttribute(.paragraphStyle, value: style, range: content.fullRange)
        content.addAttribute(.foregroundColor, value: foregroundColor, range: content.fullRange)
        applyInlineCodeStyling(to: content)

        output.append(content)
        return output
    }

    private nonisolated func thematicBreakAttributedString(quoteDepth: Int) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 16
        style.maximumLineHeight = 16
        let adjustedStyle = paragraphStyle(style, adjustedForQuoteDepth: quoteDepth)

        return NSAttributedString(
            string: "\u{200B}",
            attributes: [
                .font: NSFont.systemFont(ofSize: 1),
                .foregroundColor: NSColor.clear,
                .paragraphStyle: adjustedStyle,
                .markdownThematicBreak: true
            ]
        )
    }

    private nonisolated func listMarker(for marker: ListMarker) -> BlockContext.ListContext.Marker {
        switch marker {
        case .bullet:
            return .bullet
        case .ordered(let value):
            return .ordered(value)
        }
    }

    private nonisolated func normalizeFonts(in attributedString: NSMutableAttributedString) {
        let fullRange = attributedString.fullRange

        if fullRange.length == 0 {
            return
        }

        unsafe attributedString.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            guard let font = value as? NSFont else {
                attributedString.addAttribute(.font, value: bodyFont(), range: range)
                return
            }

            let traits = font.fontDescriptor.symbolicTraits

            // Skip monospace ranges — applyInlineCodeStyling handles inline code fonts
            guard !traits.contains(.monoSpace) else { return }

            let weight: NSFont.Weight = traits.contains(.bold) ? .semibold : .regular
            attributedString.addAttribute(.font, value: NSFont.systemFont(ofSize: bodyFontSize, weight: weight), range: range)
        }
    }

    private nonisolated func applyInlineCodeStyling(to attributedString: NSMutableAttributedString) {
        let fullRange = attributedString.fullRange
        guard fullRange.length > 0 else { return }

        unsafe attributedString.enumerateAttribute(.markdownInlinePresentationIntent, in: fullRange) { value, range, _ in
            let isInlineCode: Bool
            if let intent = value as? InlinePresentationIntent {
                isInlineCode = intent.contains(.code)
            } else {
                let rawValue = (value as? NSNumber)?.intValue ?? 0
                isInlineCode = rawValue & 4 != 0
            }

            guard isInlineCode else {
                return
            }

            let weight: NSFont.Weight
            if let existingFont = attributedString.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
               existingFont.fontDescriptor.symbolicTraits.contains(.bold) {
                weight = .semibold
            } else {
                weight = .regular
            }

            attributedString.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: weight),
                .foregroundColor: NSColor.controlAccentColor
            ], range: range)
        }
    }

    private nonisolated func codeBlockParagraphStyle() -> NSParagraphStyle {
        cachedCodeBlockParagraphStyle
    }

    private nonisolated func mergeQuoteBlocks(_ quoteBlocks: inout [MarkdownQuoteBlock], with newBlocks: [MarkdownQuoteBlock]) {
        for block in newBlocks {
            guard let lastBlock = quoteBlocks.last else {
                quoteBlocks.append(block)
                continue
            }

            let lastBlockEnd = lastBlock.range.location + lastBlock.range.length
            let gapLength = block.range.location - lastBlockEnd

            if lastBlock.identity == block.identity,
               lastBlock.depth == block.depth,
               gapLength >= 0,
               gapLength <= 2 {
                quoteBlocks[quoteBlocks.count - 1] = MarkdownQuoteBlock(
                    range: NSRange(
                        location: lastBlock.range.location,
                        length: (block.range.location + block.range.length) - lastBlock.range.location
                    ),
                    depth: block.depth,
                    identity: block.identity
                )
            } else {
                quoteBlocks.append(block)
            }
        }
    }

    private nonisolated func markerText(for marker: BlockContext.ListContext.Marker) -> String {
        switch marker {
        case .bullet:
            "•"
        case .ordered(let value):
            "\(value)."
        }
    }

    private nonisolated func paragraphStyle() -> NSParagraphStyle {
        cachedDefaultParagraphStyle
    }

    private nonisolated func quoteTextColor() -> NSColor {
        NSColor.secondaryLabelColor
    }

    private nonisolated func listParagraphStyle(markerIndent: CGFloat, marker: String) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let markerWidth: CGFloat
        if marker == "•" {
            markerWidth = cachedBulletMarkerWidth
        } else {
            markerWidth = marker.size(withAttributes: [.font: bodyFont()]).width
        }
        let contentIndent = markerIndent + markerWidth + 10
        style.firstLineHeadIndent = markerIndent
        style.headIndent = contentIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: contentIndent)]
        style.defaultTabInterval = contentIndent
        style.paragraphSpacing = 5
        return style
    }

    private nonisolated func paragraphStyle(
        _ baseStyle: NSParagraphStyle,
        adjustedForQuoteDepth quoteDepth: Int
    ) -> NSParagraphStyle {
        guard quoteDepth > 0 else { return baseStyle }

        let style = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        let quoteIndent = CGFloat(quoteDepth) * 16
        style.headIndent += quoteIndent
        style.firstLineHeadIndent += quoteIndent
        style.paragraphSpacing = max(style.paragraphSpacing, 4)
        style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, 2)
        return style
    }

    private nonisolated func headingFont(for level: Int) -> NSFont {
        switch level {
        case 1: return .systemFont(ofSize: bodyFontSize + 11, weight: .bold)
        case 2: return .systemFont(ofSize: bodyFontSize + 6, weight: .bold)
        case 3: return .systemFont(ofSize: bodyFontSize + 3, weight: .semibold)
        case 4: return .systemFont(ofSize: bodyFontSize, weight: .semibold)
        default: return .systemFont(ofSize: bodyFontSize, weight: .regular)
        }
    }

    private nonisolated func bodyFont() -> NSFont {
        .systemFont(ofSize: bodyFontSize, weight: .regular)
    }
}

private extension NSAttributedString {
    nonisolated var fullRange: NSRange {
        NSRange(location: 0, length: length)
    }
}

extension NSAttributedString.Key {
    fileprivate nonisolated static let markdownInlinePresentationIntent = Self("NSInlinePresentationIntent")
    fileprivate nonisolated static let markdownListItemDelimiter = Self("NSListItemDelimiter")
    fileprivate nonisolated static let markdownPresentationIntent = Self("NSPresentationIntent")
    fileprivate nonisolated static let markdownCodeBlockID = Self("LynkChatMarkdownCodeBlockID")
    fileprivate nonisolated static let markdownTableBlockID = Self("LynkChatMarkdownTableBlockID")
    static let markdownThematicBreak = Self("LynkChatMarkdownThematicBreak")
}
