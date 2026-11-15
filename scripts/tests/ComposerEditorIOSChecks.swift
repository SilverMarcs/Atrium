import UIKit
import SwiftUI

@MainActor final class TaskComposer { weak var textEditor: (any ComposerTextInserting)? }
@MainActor final class ComposerPasteDelegate {
    func configure(_ field: some UIView & UITextPasteConfigurationSupporting) {}
}
@main @MainActor enum ComposerEditorIOSChecks {
    struct Failure: Error { let message: String }
    static func check(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(message: message) } }
    static func main() throws {
        let editor = ComposerEditor()
        editor.text = "Hello world"
        editor.selectedRange = NSRange(location: 6, length: 0)
        try check(editor.insertDictation("brave", in: "Hello world") == "Hello brave world", "Insert at caret")
        try check(editor.selectedRange == NSRange(location: 12, length: 0), "Caret follows transcript")
        editor.text = "Hello world"
        editor.selectedRange = NSRange(location: 6, length: 5)
        try check(editor.insertDictation("friend", in: "Hello world") == "Hello friend", "Replace selection")
        let before = editor.text ?? ""
        try check(editor.insertDictation("wrong chat", in: "Another draft") == nil, "Reject an editor showing another draft")
        try check(editor.text == before, "Rejected insertion must leave the draft unchanged")
        editor.isEditable = false
        try check(editor.insertDictation("locked", in: before) == nil, "Do not change an editor while saving")
        print("iOS native editor checks passed")
    }
}
