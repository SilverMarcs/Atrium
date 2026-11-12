import SwiftUI

/// The part of the iPhone composer a subview plays, which places it.
enum PhoneComposerPart {
    /// The field's glass, which grows into the panel holding everything.
    case panel
    case attach
    case cancelEdit
    case editor
    case dictation
    case send
    /// The circle after the field at rest: Send with a draft, else Stop.
    case action
}

private struct PhoneComposerPartKey: LayoutValueKey {
    static let defaultValue = PhoneComposerPart.panel
}

extension View {
    func phoneComposerPart(_ part: PhoneComposerPart) -> some View {
        layoutValue(key: PhoneComposerPartKey.self, value: part)
    }
}

/// Lays out the iPhone composer in either of its states, so moving between
/// them animates every part from one place to the other.
///
/// At rest it's the bottom bar it replaced: the attachment button's circle,
/// then the field's capsule with the dictation button inside its end, and
/// a Send or Stop circle. Expanded, the field's
/// glass is one panel across the width: the editor on top, over a row with
/// the attachment button at its leading end and dictation and Send at its
/// trailing end.
struct PhoneComposerLayout: Layout {
    var isExpanded: Bool
    /// The draft, which the expanded editor grows to fit.
    var draft: String

    /// The system bottom bar's metrics, which the composer at rest matches.
    static let rowHeight: CGFloat = 48
    static let restingMargin: CGFloat = 28
    static let restingSpacing: CGFloat = 12
    /// Expanded, the panel nearly reaches the edges, as a focused search
    /// field does. Its corners stay concentric with the row's buttons.
    static let expandedMargin: CGFloat = 8
    static let cornerRadius: CGFloat = rowHeight / 2
    /// Between the field's end and the dictation button inside it.
    private static let dictationInset: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 402
        guard isExpanded else { return CGSize(width: width, height: Self.rowHeight) }
        return CGSize(width: width, height: editorHeight(in: width) + Self.rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = isExpanded ? expandedFrames(in: bounds, subviews: subviews) : restingFrames(in: bounds, subviews: subviews)
        for subview in subviews {
            let frame = frames[subview[PhoneComposerPartKey.self]] ?? .zero
            subview.place(at: frame.origin, anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func has(_ part: PhoneComposerPart, in subviews: Subviews) -> Bool {
        subviews.contains { $0[PhoneComposerPartKey.self] == part }
    }

    private func size(of part: PhoneComposerPart, in subviews: Subviews) -> CGSize {
        subviews.first { $0[PhoneComposerPartKey.self] == part }?.sizeThatFits(.unspecified) ?? .zero
    }

    private func editorHeight(in width: CGFloat) -> CGFloat {
        let panelWidth = width - Self.expandedMargin * 2
        return ComposerEditor.expandedHeight(of: draft, width: panelWidth, maximumLines: ComposerTextView.maximumLines)
    }

    /// A button's frame centered in a row-sized cell.
    private func centered(_ size: CGSize, inCellAt x: CGFloat, y: CGFloat, width: CGFloat = rowHeight) -> CGRect {
        CGRect(x: x + (width - size.width) / 2, y: y + (Self.rowHeight - size.height) / 2,
               width: size.width, height: size.height)
    }

    private func restingFrames(in bounds: CGRect, subviews: Subviews) -> [PhoneComposerPart: CGRect] {
        let row = Self.rowHeight
        let y = bounds.maxY - row
        var frames: [PhoneComposerPart: CGRect] = [:]
        var leading = bounds.minX + Self.restingMargin
        var trailing = bounds.maxX - Self.restingMargin

        frames[.attach] = CGRect(x: leading, y: y, width: row, height: row)
        if has(.attach, in: subviews) { leading += row + Self.restingSpacing }
        if has(.cancelEdit, in: subviews) {
            frames[.cancelEdit] = CGRect(x: leading, y: y, width: row, height: row)
            leading += row + Self.restingSpacing
        }
        if has(.action, in: subviews) {
            frames[.action] = CGRect(x: trailing - row, y: y, width: row, height: row)
            trailing -= row + Self.restingSpacing
        }
        frames[.panel] = CGRect(x: leading, y: y, width: max(trailing - leading, 0), height: row)

        var editorEnd = trailing
        let dictation = size(of: .dictation, in: subviews)
        if has(.dictation, in: subviews) {
            let x = trailing - Self.dictationInset - dictation.width
            frames[.dictation] = CGRect(x: x, y: y + (row - dictation.height) / 2, width: dictation.width, height: dictation.height)
            editorEnd = x
        }
        // Send waits, hidden, at the field's end.
        let send = size(of: .send, in: subviews)
        frames[.send] = centered(send, inCellAt: trailing - row, y: y)
        frames[.editor] = CGRect(x: leading, y: y, width: max(editorEnd - leading, 0), height: row)
        return frames
    }

    private func expandedFrames(in bounds: CGRect, subviews: Subviews) -> [PhoneComposerPart: CGRect] {
        let row = Self.rowHeight
        let leading = bounds.minX + Self.expandedMargin
        let trailing = bounds.maxX - Self.expandedMargin
        let editorHeight = editorHeight(in: bounds.width)
        let top = bounds.maxY - row - editorHeight
        let rowY = bounds.maxY - row
        var frames: [PhoneComposerPart: CGRect] = [:]

        frames[.panel] = CGRect(x: leading, y: top, width: trailing - leading, height: editorHeight + row)
        frames[.editor] = CGRect(x: leading, y: top, width: trailing - leading, height: editorHeight)
        frames[.attach] = CGRect(x: leading, y: rowY, width: row, height: row)
        let cancelX = has(.attach, in: subviews) ? leading + row : leading
        frames[.cancelEdit] = CGRect(x: cancelX, y: rowY, width: row, height: row)

        // The action circle melts into the cell Send takes.
        let sendCell = trailing - row
        frames[.send] = centered(size(of: .send, in: subviews), inCellAt: sendCell, y: rowY)
        frames[.action] = CGRect(x: sendCell, y: rowY, width: row, height: row)
        let dictation = size(of: .dictation, in: subviews)
        frames[.dictation] = CGRect(x: sendCell - dictation.width, y: rowY + (row - dictation.height) / 2,
                                    width: dictation.width, height: dictation.height)
        return frames
    }
}
