import Foundation

/// A draft that runs in the project's terminal instead of going to the agent:
/// "!", a space, then a command, as in "! git status".
///
/// It reads the draft as a person would. "!important" or "!!" names no
/// command, and neither does a draft that opens with "! " and then writes
/// prose: an exclamation such as "! Wait, stop", a sentence such as
/// "! This is still broken" or "! don't do that", or Markdown such as
/// "! [the docs](…)". A command can run over several lines, as a script does.
nonisolated struct ShellCommandDraft: Equatable, Sendable {
    /// What runs: the draft after "! ", without the blank space around it.
    let command: String
    /// From the "!" to the end of the command, in UTF-16 offsets, for the editor to tint.
    let range: NSRange

    init?(_ draft: String) {
        let text = draft as NSString
        // A draft starting on a blank line still counts.
        let start = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        guard start.location != NSNotFound, text.character(at: start.location) == Self.bang,
              start.location + 1 < text.length,
              Self.isBlank(text.character(at: start.location + 1)) else { return nil }
        let rest = text.substring(from: start.location + 1)
        let command = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, Self.looksLikeCommand(command) else { return nil }
        self.command = command
        let end = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards).upperBound
        range = NSRange(location: start.location, length: end - start.location)
    }

    // MARK: - Reading it

    /// Whether `command` reads as something to run rather than a sentence.
    private static func looksLikeCommand(_ command: String) -> Bool {
        let firstLine = command.prefix { !$0.isNewline }
        let words = firstLine.split(whereSeparator: \.isWhitespace)
        guard let first = words.first, let initial = first.unicodeScalars.first else { return false }
        // Programs, paths, variables, subshells and quoted words start this
        // way; prose punctuation, emoji and other scripts don't.
        guard initial.isASCII, CharacterSet.alphanumerics.contains(initial) || commandStarts.contains(initial) else { return false }
        // `[` and `{` start a command only as a word of their own, as in
        // `[ -f x ]`; "[the docs](…)" is a link.
        if "[{".unicodeScalars.contains(initial), !["[", "[[", "{"].contains(first) { return false }
        // "Wait," or "Hmm?" opens a sentence.
        if first.count > 1, let last = first.last, ",:?!".contains(last),
           first.dropLast().last?.isLetter == true { return false }
        // A capitalised word opens a sentence, as in "This is still broken"
        // or "Wait"; programs are named in lower case.
        if initial.properties.isUppercase,
           first.dropFirst().allSatisfy({ $0.isASCII && $0.isLowercase }) { return false }
        return !hasOpenSingleQuote(firstLine)
    }

    /// Whether a ' is left open, as an apostrophe leaves one in "don't",
    /// where a shell would wait for the quote to close.
    private static func hasOpenSingleQuote(_ line: Substring) -> Bool {
        var inSingle = false
        var inDouble = false
        var isEscaped = false
        for character in line {
            if isEscaped {
                isEscaped = false
            } else if character == "\\", !inSingle {
                isEscaped = true
            } else if character == "'", !inDouble {
                inSingle.toggle()
            } else if character == "\"", !inSingle {
                inDouble.toggle()
            }
        }
        return inSingle
    }

    private static let bang = unichar(UInt8(ascii: "!"))
    private static let commandStarts = CharacterSet(charactersIn: "./~$_([{\"'\\")

    private static func isBlank(_ character: unichar) -> Bool {
        character == unichar(UInt8(ascii: " ")) || character == unichar(UInt8(ascii: "\t"))
    }
}
