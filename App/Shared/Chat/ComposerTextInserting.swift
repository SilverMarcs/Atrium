import Foundation

/// The native editor owns its selection and undo stack, including during dictation.
@MainActor
protocol ComposerTextInserting: AnyObject {
    func insertDictation(_ transcript: String, in draft: String) -> String?
}
