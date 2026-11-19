import Foundation

/// The native editor owns its selection and undo stack, including during dictation.
@MainActor
protocol ComposerTextInserting: AnyObject {
    func insertDictation(_ transcript: String, in draft: String) -> String?
    /// Replaces `range` of `draft` with `text` as typing would, leaving the
    /// caret after it, and returns the new draft; nil when the editor isn't
    /// showing `draft`.
    func replace(_ range: NSRange, with text: String, in draft: String) -> String?
}
