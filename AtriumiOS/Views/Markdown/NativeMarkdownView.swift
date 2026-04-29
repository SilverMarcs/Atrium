import SwiftUI

enum MarkdownPart: Equatable {
    case text(String)
    case codeBlock(String)
    case heading(level: Int, text: String)
    case list(items: [ListItem])
    case table(headers: [String], alignments: [TableColumnAlignment], rows: [[String]])
}

enum TableColumnAlignment: Equatable {
    case left, center, right
}

struct ListItem: Equatable, Identifiable {
    enum Marker: Equatable {
        case bullet
        case ordered(Int)
    }
    let id = UUID()
    var marker: Marker
    var content: String
    var level: Int // 1 = top-level
    var children: [ListItem] = []
}

struct NativeMarkdownView: View {
    private let parts: [MarkdownPart]
    
    init(text: String) {
        self.parts = NativeMarkdownView.parseMarkdown(text)
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let string):
                    Text(LocalizedStringKey(string))
                        .lineSpacing(2)

                case .codeBlock(let code):
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(code)
                            .font(.callout)
                            .monospaced()
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(12)
                    }
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                case .heading(let level, let text):
                    headingView(level: level, text: text)

                case .list(let items):
                    listView(items: items)

                case .table(let headers, let alignments, let rows):
                    tableView(headers: headers, alignments: alignments, rows: rows)
                }
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Heading Rendering

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        // Map Markdown heading levels to SwiftUI fonts
        let font: Font = {
            switch level {
            case 1: return .title.bold()
            case 2: return .title2.bold()
            case 3: return .title3.weight(.semibold)
            case 4: return .headline.weight(.semibold)
            case 5: return .subheadline
            default: return .subheadline
            }
        }()
        Text(LocalizedStringKey(text))
            .font(font)
            .padding(.top, 2)
    }

    // MARK: - List Rendering (Recursive)

    @ViewBuilder
    private func listView(items: [ListItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    markerView(for: item.marker)
                        .frame(width: 16, alignment: .trailing)
                    Text(LocalizedStringKey(item.content))
                        .lineSpacing(2)
                }
                .padding(.leading, CGFloat(max(0, item.level - 1)) * 16)
            }
        }
    }

    @ViewBuilder
    private func markerView(for marker: ListItem.Marker) -> some View {
        switch marker {
        case .bullet:
            Circle()
                .fill(.primary)
                .frame(width: 4, height: 4)
                .offset(y: -2.5)
        case .ordered(let n):
            Text("\(n).")
        }
    }

    // MARK: - Table Rendering

    @ViewBuilder
    private func tableView(headers: [String], alignments: [TableColumnAlignment], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)

        let styledGrid = Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { idx in
                    tableCellView(
                        text: idx < headers.count ? headers[idx] : "",
                        alignment: idx < alignments.count ? alignments[idx] : .left,
                        isHeader: true
                    )
                }
            }
            .background(.secondary.opacity(0.18))

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { idx in
                        tableCellView(
                            text: idx < row.count ? row[idx] : "",
                            alignment: idx < alignments.count ? alignments[idx] : .left,
                            isHeader: false
                        )
                    }
                }
                .background(rowIdx.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.secondary.opacity(0.25), lineWidth: 0.5)
        )

        ViewThatFits(in: .horizontal) {
            styledGrid
            ScrollView(.horizontal, showsIndicators: true) {
                styledGrid
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func tableCellView(text: String, alignment: TableColumnAlignment, isHeader: Bool) -> some View {
        let frameAlignment: Alignment = {
            switch alignment {
            case .left: return .leading
            case .center: return .center
            case .right: return .trailing
            }
        }()
        let textAlignment: TextAlignment = {
            switch alignment {
            case .left: return .leading
            case .center: return .center
            case .right: return .trailing
            }
        }()

        Text(LocalizedStringKey(text))
            .font(isHeader ? .body.weight(.semibold) : .body)
            .multilineTextAlignment(textAlignment)
            .lineSpacing(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
    }

    // MARK: - Parser

    private static func parseMarkdown(_ text: String) -> [MarkdownPart] {
        var parts: [MarkdownPart] = []
        let lines = text.components(separatedBy: .newlines)

        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Handle code blocks (``` or ```lang)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                var codeLines: [String] = []
                i += 1 // Skip opening ```
                while i < lines.count {
                    let codeLine = lines[i]
                    if codeLine.trimmingCharacters(in: .whitespaces) == "```" {
                        break
                    }
                    codeLines.append(codeLine)
                    i += 1
                }
                parts.append(.codeBlock(codeLines.joined(separator: "\n")))
                i += 1 // Skip closing ```
                continue
            }

            // Handle headings: # .. ###### + space
            if let heading = parseHeading(line: line) {
                parts.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            // Handle list block (bulleted or ordered, supports nesting)
            if isListLine(line) {
                let (listItems, nextIndex) = parseListBlock(from: i, lines: lines)
                parts.append(.list(items: listItems))
                i = nextIndex
                continue
            }

            // Handle table block (header row + separator + body rows)
            if let (table, nextIndex) = parseTableBlock(from: i, lines: lines) {
                parts.append(table)
                i = nextIndex
                continue
            }

            // Collect consecutive non-special lines as regular text
            var textLines: [String] = []
            while i < lines.count {
                let currentLine = lines[i]
                let trimmed = currentLine.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("```")
                    || isListLine(currentLine)
                    || parseHeading(line: currentLine) != nil
                    || isTableStart(at: i, lines: lines)
                {
                    break
                }

                textLines.append(currentLine)
                i += 1
            }

            if !textLines.isEmpty {
                parts.append(.text(textLines.joined(separator: "\n")))
            } else {
                // empty line
                i += 1
            }
        }

        return parts
    }

    // MARK: - Helpers: Headings

    private static func parseHeading(line: String) -> (level: Int, text: String)? {
        // Match leading #'s followed by a space
        // e.g. "### Title"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "#" else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard hashes.count >= 1 && hashes.count <= 6 else { return nil }
        let remainder = trimmed.dropFirst(hashes.count)
        guard remainder.first == " " else { return nil }
        let text = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
        return (level: hashes.count, text: String(text))
    }

    // MARK: - Helpers: Lists

    private static func isListLine(_ line: String) -> Bool {
        let s = line
        let pattern = #"^\s*(?:[-*+]\s+|\d+\.\s+)"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    private static func parseListBlock(from start: Int, lines: [String]) -> ([ListItem], Int) {
        var i = start
        var items: [ListItem] = []

        // Collect contiguous list lines (stopping at blank line or non-list)
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard let parsed = parseListLine(line) else { break }
            items.append(parsed)
            i += 1
        }

        // Return a flat list; indentation handled by rendering with padding
        return (items, i)
    }

    private static func parseListLine(_ line: String) -> ListItem? {
        let lineChars = Array(line)
        let spaces = countLeadingSpaces(in: lineChars)
        // Use 2-space steps to define nesting; tabs assumed as 4 spaces
        let level = max(1, spaces / 2 + 1)

        let trimmed = String(line.dropFirst(spaces))

        // Ordered: n. content
        if let orderedRange = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            let markerStr = String(trimmed[orderedRange])
            let numStr = markerStr.trimmingCharacters(in: .whitespaces).dropLast().split(separator: ".").first ?? ""
            let n = Int(numStr) ?? 1
            let content = String(trimmed[orderedRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            return ListItem(marker: .ordered(n), content: content, level: level, children: [])
        }

        // Bulleted: -, *, +
        if let bulletRange = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
            let content = String(trimmed[bulletRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            return ListItem(marker: .bullet, content: content, level: level, children: [])
        }

        return nil
    }

    private static func countLeadingSpaces(in chars: [Character]) -> Int {
        var count = 0
        for c in chars {
            if c == " " { count += 1 }
            else if c == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    // Removed complex tree building; using flat list rendering for simplicity

    // MARK: - Helpers: Tables

    private static func isTableStart(at index: Int, lines: [String]) -> Bool {
        guard index + 1 < lines.count else { return false }
        let header = lines[index]
        guard header.contains("|") else { return false }
        return parseTableSeparator(lines[index + 1]) != nil
    }

    private static func parseTableBlock(from start: Int, lines: [String]) -> (MarkdownPart, Int)? {
        guard isTableStart(at: start, lines: lines) else { return nil }
        guard let alignments = parseTableSeparator(lines[start + 1]) else { return nil }

        let headers = parseTableRow(lines[start])
        var rows: [[String]] = []
        var i = start + 2
        while i < lines.count {
            let row = lines[i]
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if !trimmed.contains("|") { break }
            // Stop if we've hit another structural element
            if parseHeading(line: row) != nil { break }
            if trimmed.hasPrefix("```") { break }
            rows.append(parseTableRow(row))
            i += 1
        }

        return (.table(headers: headers, alignments: alignments, rows: rows), i)
    }

    private static func parseTableSeparator(_ line: String) -> [TableColumnAlignment]? {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard s.contains("|") || s.contains("-") else { return nil }
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        let cells = s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !cells.isEmpty else { return nil }

        var alignments: [TableColumnAlignment] = []
        for cell in cells {
            guard cell.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else {
                return nil
            }
            let starts = cell.hasPrefix(":")
            let ends = cell.hasSuffix(":")
            if starts && ends { alignments.append(.center) }
            else if ends { alignments.append(.right) }
            else { alignments.append(.left) }
        }
        return alignments
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        // Preserve escaped pipes (\|) so they don't split cells.
        let placeholder = "\u{FFFC}"
        s = s.replacingOccurrences(of: "\\|", with: placeholder)
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: placeholder, with: "|")
            }
    }
}
 

//extension AttributedString {
//    init(styledMarkdown markdownString: String) throws {
//        var output = try AttributedString(
//            markdown: markdownString,
//            options: .init(
//                allowsExtendedAttributes: true,
//                interpretedSyntax: .full,
//                failurePolicy: .returnPartiallyParsedIfPossible
//            ),
//            baseURL: nil
//        )
//
//        for (intentBlock, intentRange) in output.runs[AttributeScopes.FoundationAttributes.PresentationIntentAttribute.self].reversed() {
//            guard let intentBlock = intentBlock else { continue }
//            for intent in intentBlock.components {
//                switch intent.kind {
//                case .header(level: let level):
//                    switch level {
//                    case 1:
//                        output[intentRange].font = .system(.title).bold()
//                    case 2:
//                        output[intentRange].font = .system(.title2).bold()
//                    case 3:
//                        output[intentRange].font = .system(.title3).bold()
//                    default:
//                        break
//                    }
//                default:
//                    break
//                }
//            }
//            
//            if intentRange.lowerBound != output.startIndex {
//                output.characters.insert(contentsOf: "\n", at: intentRange.lowerBound)
//            }
//        }
//
//        self = output
//    }
//}
