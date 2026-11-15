import Foundation

@main
enum ComposerDictationInsertionChecks {
    struct Failure: Error { let message: String }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() throws {
        let middle = ComposerDictationInsertion(transcript: "brave", draft: "Hello world", selection: NSRange(location: 6, length: 0))
        try check(middle.text == "brave ", "Separate the transcript from text after the caret")
        try check(middle.applying(to: "Hello world") == "Hello brave world", "Insert at the caret instead of appending")

        let selection = ComposerDictationInsertion(transcript: "new", draft: "The old idea", selection: NSRange(location: 4, length: 3))
        try check(selection.applying(to: "The old idea") == "The new idea", "Replace selected text")
        let end = ComposerDictationInsertion(transcript: "world", draft: "Hello", selection: nil)
        try check(end.applying(to: "Hello") == "Hello world", "Append with a separator if no editor is available")
        let start = ComposerDictationInsertion(transcript: "Hello", draft: "world", selection: NSRange(location: 0, length: 0))
        try check(start.applying(to: "world") == "Hello world", "Insert at the start")
        let punctuation = ComposerDictationInsertion(transcript: "world", draft: "Hello!", selection: NSRange(location: 5, length: 0))
        try check(punctuation.applying(to: "Hello!") == "Hello world!", "Do not put a space before punctuation")
        let emoji = ComposerDictationInsertion(transcript: "friend", draft: "Hi 🧑🏽‍💻!", selection: NSRange(location: 3, length: "🧑🏽‍💻".utf16.count))
        try check(emoji.applying(to: "Hi 🧑🏽‍💻!") == "Hi friend!", "Use native UTF-16 selections with emoji")
        let invalid = ComposerDictationInsertion(transcript: "there", draft: "Hi", selection: NSRange(location: NSNotFound, length: 0))
        try check(invalid.applying(to: "Hi") == "Hi there", "Fall back safely for an invalid selection")
        let newline = ComposerDictationInsertion(transcript: "next", draft: "Hi\n", selection: nil)
        try check(newline.applying(to: "Hi\n") == "Hi\nnext", "Preserve existing whitespace")
        let empty = ComposerDictationInsertion(transcript: "", draft: "Keep me", selection: NSRange(location: 0, length: 7))
        try check(empty.applying(to: "Keep me") == "Keep me", "An empty transcript must not delete selected text")
        print("Composer dictation insertion checks passed")
    }
}
