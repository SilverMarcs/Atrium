import Foundation

/// The skill name being typed at the caret: a / at the start of the draft or
/// after whitespace, then the name up to the caret, which may still be empty.
struct ComposerSkillQuery: Equatable {
    /// From the / to the caret, in UTF-16 offsets.
    let range: NSRange
    let name: String

    /// The query at `selection`, or at the end of `draft` when there's none
    /// yet. A selection of more than the caret has no query.
    init?(draft: String, selection: NSRange?) {
        let caret = selection ?? NSRange(location: draft.utf16.count, length: 0)
        guard caret.length == 0, let end = Range(caret, in: draft)?.lowerBound else { return nil }
        let prefix = draft[..<end]
        guard let slash = prefix.lastIndex(where: { $0 == "/" || $0.isWhitespace }), prefix[slash] == "/",
              slash == prefix.startIndex || prefix[prefix.index(before: slash)].isWhitespace else { return nil }
        let location = slash.utf16Offset(in: draft)
        range = NSRange(location: location, length: caret.location - location)
        name = String(prefix[prefix.index(after: slash)...])
    }
}
