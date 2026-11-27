import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The skills a prompt names: a / at the start or after whitespace, then a
/// known skill's whole name, up to whitespace, closing punctuation or the
/// end. The composer and
/// the prompt bubbles tint them, so the user sees which skills a prompt uses.
enum SkillMentions {
    /// The skills named in `text`, in UTF-16 offsets.
    static func ranges(in text: String, names: Set<String>) -> [NSRange] {
        guard !names.isEmpty, text.contains("/") else { return [] }
        let string = text as NSString
        let length = string.length
        var ranges: [NSRange] = []
        var index = 0
        while index < length {
            guard string.character(at: index) == slash,
                  index == 0 || isWhitespace(string.character(at: index - 1)) else {
                index += 1
                continue
            }
            var wordEnd = index + 1
            while wordEnd < length, !isWhitespace(string.character(at: wordEnd)) { wordEnd += 1 }
            // A skill ending a sentence, as in "/review, then…", leaves its
            // punctuation out.
            var end = wordEnd
            while end > index + 1 {
                if names.contains(string.substring(with: NSRange(location: index + 1, length: end - index - 1))) {
                    ranges.append(NSRange(location: index, length: end - index))
                    break
                }
                guard isTrailingPunctuation(string.character(at: end - 1)) else { break }
                end -= 1
            }
            index = wordEnd
        }
        return ranges
    }

    /// `text` with its skills in `tint`.
    static func attributed(_ text: String, names: Set<String>, tint: Color) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges(in: text, names: names) {
            guard let swiftRange = Range(range, in: text),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].foregroundColor = tint
        }
        return attributed
    }

    #if os(iOS)
    typealias PlatformColor = UIColor
    #else
    typealias PlatformColor = NSColor
    #endif

    /// The app's accent, which the skills take in an editor.
    static var editorTint: PlatformColor {
        PlatformColor(named: "AccentColor") ?? .systemBlue
    }

    /// What an editor last tinted, so a draft that names no skills is never restyled.
    struct Styling: Equatable {
        var text = ""
        var ranges: [NSRange] = []
    }

    /// Tints the skills `names` in `storage`, leaving the rest in `textColor`,
    /// or the whole of a shell command, which names no skills. Only the colour
    /// changes, so the font, caret and undo stay as they are. Returns what it
    /// tinted, for the next call's `previous`.
    static func style(
        _ storage: NSTextStorage,
        names: Set<String>,
        shellCommand: NSRange?,
        previous: Styling,
        textColor: PlatformColor
    ) -> Styling {
        let text = storage.string
        let ranges = shellCommand.map { [$0] } ?? ranges(in: text, names: names)
        let styling = Styling(text: text, ranges: ranges)
        guard !(ranges.isEmpty && previous.ranges.isEmpty), styling != previous else { return styling }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: 0, length: storage.length))
        for range in ranges {
            storage.addAttribute(.foregroundColor, value: editorTint, range: range)
        }
        storage.endEditing()
        return styling
    }

    private static let slash = unichar(UInt8(ascii: "/"))

    private static let trailingPunctuation = Set(".,;:!?)]}'\"".utf16)

    private static func isTrailingPunctuation(_ character: unichar) -> Bool {
        trailingPunctuation.contains(character)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return scalar.properties.isWhitespace
    }
}

extension EnvironmentValues {
    /// The names of the skills the chat's task can use, for tinting them in its prompts.
    @Entry var skillNames: Set<String> = []
}
