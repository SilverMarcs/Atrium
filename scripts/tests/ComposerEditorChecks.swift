import AppKit
import SwiftUI

// Only the editor's unrelated collaborators are replaced. The actual
// representable, native editor, insertion logic and undo stack run below.
@MainActor
final class TaskComposer {
    weak var textEditor: (any ComposerTextInserting)?
}

@MainActor
final class ComposerPasteDelegate {
    func paste(from pasteboard: NSPasteboard, into editor: NSTextView) -> Bool { false }
}

@main
@MainActor
enum ComposerEditorChecks {
    struct Failure: Error { let message: String }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() throws {
        _ = NSApplication.shared
        let editor = ComposerEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = editor
        defer { window.close() }
        editor.string = "Hello world"
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        // Dictation must work after its button takes focus away from the field.
        window.makeFirstResponder(nil)
        editor.undoManager?.beginUndoGrouping()
        let inserted = editor.insertDictation("brave", in: "Hello world")
        editor.undoManager?.endUndoGrouping()
        try check(inserted == "Hello brave world", "Native editor must insert at the retained caret")
        try check(editor.selectedRange() == NSRange(location: 12, length: 0), "Caret must follow inserted text")
        try check(editor.undoManager?.canUndo == true, "Dictation must be undoable")
        editor.undoManager?.undo()
        try check(editor.string == "Hello world", "Undo must restore the original draft")

        editor.setSelectedRange(NSRange(location: 6, length: 5))
        try check(editor.insertDictation("friend", in: "Hello world") == "Hello friend", "Native editor must replace selected text")
        let before = editor.string
        try check(editor.insertDictation("wrong chat", in: "Another draft") == nil, "Do not insert into an editor displaying another draft")
        try check(editor.string == before, "A rejected insertion must leave the editor unchanged")
        editor.isEditable = false
        try check(editor.insertDictation("locked", in: before) == nil, "Do not change an editor while saving")
        print("Native composer editor checks passed")
    }
}
