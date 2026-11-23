import Foundation

/// Adds word separators around a transcript without disturbing surrounding text.
struct ComposerDictationInsertion {
    let text: String
    let range: NSRange

    init(transcript: String, draft: String, selection: NSRange?) {
        let selected = selection.flatMap { Range($0, in: draft) } ?? draft.endIndex..<draft.endIndex
        guard !transcript.isEmpty else {
            text = ""
            range = NSRange(location: selected.lowerBound.utf16Offset(in: draft), length: 0)
            return
        }
        let before = draft[..<selected.lowerBound].last
        let after = draft[selected.upperBound...].first
        let leading = before.map { !$0.isWhitespace } == true
            && transcript.first.map { !$0.isWhitespace && !$0.isPunctuation } == true
        let trailing = after.map { !$0.isWhitespace && !$0.isPunctuation } == true
            && transcript.last.map { !$0.isWhitespace } == true
        text = (leading ? " " : "") + transcript + (trailing ? " " : "")
        range = NSRange(selected, in: draft)
    }

    func applying(to draft: String) -> String {
        guard let range = Range(range, in: draft) else { return draft }
        return draft.replacingCharacters(in: range, with: text)
    }
}
